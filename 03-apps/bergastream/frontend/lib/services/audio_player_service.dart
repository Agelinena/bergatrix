import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../models/track.dart';
import '../core/api_client.dart';
import 'offline_service.dart';
import '../providers/player_provider.dart' show PlayerStatus;

part 'audio_player_service.g.dart';

/// Toggle for the just_audio_background MediaItem tag.  When true,
/// AudioSource.uri receives a MediaItem and the lockscreen / notification
/// controls come up; when false we use a plain Map tag (no notification).
const _useBackgroundMediaItem = true;

@Riverpod(keepAlive: true)
AudioPlayerService audioPlayerService(AudioPlayerServiceRef ref) {
  final service = AudioPlayerService(ref.read(apiClientProvider));
  ref.onDispose(service.dispose);
  return service;
}

/// Wraps a [AudioPlayer] backed by a long-lived [ConcatenatingAudioSource].
///
/// The concat lives for the lifetime of the service — every queue
/// change goes through clear()/addAll()/insert()/removeAt()/move()
/// instead of setAudioSource(new).  That matters on Android: setting a
/// new source tears down the foreground service for a moment, and the
/// OS can kill the process between tracks (the "music stops after the
/// first song" bug we hit when the screen was off).  Holding the same
/// concat source keeps the foreground service alive across transitions,
/// and as a bonus exposes skipToNext / skipToPrevious to the
/// notification, since ExoPlayer now knows there's a real playlist.
class AudioPlayerService {
  final ApiClient _client;
  final AudioPlayer _player = AudioPlayer();
  final ConcatenatingAudioSource _concat =
      ConcatenatingAudioSource(children: []);
  bool _sessionConfigured = false;
  bool _concatInstalled = false;

  /// Last error captured from the player, exposed so the UI can show it.
  String? lastError;

  /// Crossfade duration in milliseconds.  When > 0, [playQueue] ramps
  /// volume from 0 → [_userVolume] over [crossfadeMs] (fade-in) and
  /// [fadeOut] ramps volume from current → 0 over [crossfadeMs].  The
  /// player provider calls [fadeOut] near the end of a track and
  /// schedules a [seekToNext] so the two ramps overlap perceptually.
  int crossfadeMs = 0;

  /// The "real" target volume set by the user via [setVolume].  We track
  /// it separately because fade ramps temporarily move the playing
  /// player's volume below the user-chosen target.
  double _userVolume = 1.0;

  /// Active fade-ramp tick — cancelled when a new fade starts or
  /// [setVolume] is called, so concurrent fades don't fight each other.
  int _fadeGeneration = 0;

  void Function(Duration)? onPositionChanged;
  void Function(Duration)? onDurationChanged;
  void Function(PlayerStatus)? onStatusChanged;
  void Function()? onTrackComplete;
  void Function(String error)? onError;

  /// Fires whenever the underlying ExoPlayer advances/retreats to a
  /// different item in [_concat] — either because it finished a track
  /// naturally or because [seekToNext] / [seekToPrevious] was called.
  /// Used by the Player provider to keep its [PlayerState.queueIndex]
  /// in sync with the real playback position.
  void Function(int)? onCurrentIndexChanged;

  AudioPlayerService(this._client) {
    debugPrint('[AudioPlayer] constructor: created AudioPlayer instance');
    _player.positionStream.listen((pos) => onPositionChanged?.call(pos));
    _player.durationStream.listen((dur) => onDurationChanged?.call(dur ?? Duration.zero));
    _player.currentIndexStream.listen((idx) {
      if (idx != null) {
        debugPrint('[AudioPlayer] currentIndex=$idx');
        onCurrentIndexChanged?.call(idx);
      }
    });
    _player.processingStateStream.listen((state) {
      debugPrint('[AudioPlayer] processingState=$state');
      // Only the FINAL item's completion bubbles up as "completed" — the
      // concat handles intra-track transitions internally, which is
      // exactly what we want.
      if (state == ProcessingState.completed) onTrackComplete?.call();
    });
    _player.playingStream.listen((playing) {
      onStatusChanged?.call(playing ? PlayerStatus.playing : PlayerStatus.paused);
    });
    _player.playbackEventStream.listen(
      (event) {},
      onError: (Object e, StackTrace st) {
        final msg = '$e';
        lastError = msg;
        debugPrint('[AudioPlayer] playbackEvent error: $e\n$st');
        onError?.call(msg);
        onStatusChanged?.call(PlayerStatus.error);
      },
    );
    _player.playerStateStream.listen((s) {
      debugPrint('[AudioPlayer] playerState: playing=${s.playing} state=${s.processingState}');
    });
  }

  Future<void> _ensureSession() async {
    if (_sessionConfigured) return;
    if (kIsWeb) {
      _sessionConfigured = true;
      return;
    }
    try {
      final session = await AudioSession.instance.timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw TimeoutException(
          'AudioSession.instance timed out (5s)', const Duration(seconds: 5),
        ),
      );
      await session.configure(const AudioSessionConfiguration.music()).timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw TimeoutException(
          'session.configure timed out (5s)', const Duration(seconds: 5),
        ),
      );
      _sessionConfigured = true;
      debugPrint('[AudioPlayer] AudioSession configured (music profile)');
    } catch (e, st) {
      debugPrint('[AudioPlayer] AudioSession.configure failed (non-fatal): $e\n$st');
    }
  }

  Future<T> _step<T>(String label, Duration timeout, Future<T> Function() task) {
    return task().timeout(
      timeout,
      onTimeout: () => throw TimeoutException(
        'Audio player travou em "$label" após ${timeout.inSeconds}s',
        timeout,
      ),
    );
  }

  /// Builds a single [AudioSource] for [track].
  ///
  /// If the track is downloaded offline, the source points at the LOCAL FILE
  /// (`file://…`) so playback works with no network and skips the server
  /// entirely.  Otherwise it streams from the server using the current JWT.
  /// Async because the offline check hits the filesystem.
  Future<AudioSource> _sourceFor(Track track, String? token) async {
    final localPath = kIsWeb ? null : await OfflineService.localPath(track.id);
    final Uri uri = localPath != null
        ? Uri.file(localPath)
        : Uri.parse(_client.streamUrl(track.id, token: token));
    final Object tag = (_useBackgroundMediaItem && !kIsWeb)
        ? MediaItem(
            id: track.id,
            title: track.title.isNotEmpty ? track.title : 'Faixa desconhecida',
            artist: track.artist,
            album: track.album,
            artUri: _safeArtUri(track.coverUrl),
            duration: track.durationMs != null
                ? Duration(milliseconds: track.durationMs!)
                : null,
          )
        : _legacyTag(track);
    return AudioSource.uri(uri, tag: tag);
  }

  /// Convenience: replaces the queue with a single track.
  Future<void> play(Track track) => playQueue([track], 0);

  /// Replace the playback queue with [queue] starting at [startIndex].
  ///
  /// The first call wires the long-lived [_concat] as the player's
  /// audio source and starts playback.  Subsequent calls mutate the
  /// concat in place via clear() + addAll() instead of recreating it,
  /// so the foreground service stays alive — critical for Android
  /// background playback resilience.
  Future<void> playQueue(List<Track> queue, int startIndex) async {
    if (queue.isEmpty) return;
    final clampedStart = startIndex.clamp(0, queue.length - 1);
    final t0 = DateTime.now();
    debugPrint('[AudioPlayer] playQueue START len=${queue.length} '
        'startIndex=$clampedStart');
    lastError = null;
    try {
      await _step('ensureSession', const Duration(seconds: 10), _ensureSession);
      debugPrint('[AudioPlayer] +${DateTime.now().difference(t0).inMilliseconds}ms session ok');

      final token = await _step('getToken', const Duration(seconds: 3),
          () => _client.getToken());

      final sources = await Future.wait(queue.map((t) => _sourceFor(t, token)));

      if (!_concatInstalled) {
        // First-ever play: install the concat as the player's source.
        await _concat.addAll(sources);
        await _step(
          'setAudioSource',
          const Duration(seconds: 30),
          () => _player.setAudioSource(_concat, initialIndex: clampedStart),
        );
        _concatInstalled = true;
      } else {
        // In-place queue swap.  clear()/addAll() are concat operations
        // that don't tear down the player or its foreground service.
        await _concat.clear();
        await _concat.addAll(sources);
        try {
          await _player.seek(Duration.zero, index: clampedStart);
        } catch (e) {
          debugPrint('[AudioPlayer] seek-after-swap failed: $e');
        }
      }

      // Fade-in: if crossfade is enabled, start at volume 0 and ramp up
      // to the user-chosen target over crossfadeMs.  Otherwise jump
      // straight to userVolume.
      if (crossfadeMs > 0) {
        try { await _player.setVolume(0); } catch (_) {}
        unawaited(_rampVolume(0.0, _userVolume, crossfadeMs));
      } else {
        try { await _player.setVolume(_userVolume); } catch (_) {}
      }

      // Fire-and-forget — just_audio's play() future only resolves when
      // playback ENDS, so awaiting it would hang us forever.
      unawaited(_player.play());
      debugPrint('[AudioPlayer] +${DateTime.now().difference(t0).inMilliseconds}ms '
          'play() invoked (fire-and-forget)');
    } catch (e, st) {
      final elapsed = DateTime.now().difference(t0).inMilliseconds;
      final msg = '$e';
      // "Connection aborted" from just_audio is the benign result of a
      // newer queue swap arriving mid-load; suppress it so the UI
      // doesn't flash an error SnackBar.
      final isAbort = msg.contains('Connection aborted') ||
          msg.contains('OperationAborted') ||
          msg.contains('PlatformException(abort');
      if (isAbort) {
        debugPrint('[AudioPlayer] playQueue aborted after ${elapsed}ms (benign)');
        return;
      }
      lastError = '$e (após ${elapsed}ms)';
      debugPrint('[AudioPlayer] playQueue failed after ${elapsed}ms: $e\n$st');
      onError?.call(lastError!);
      onStatusChanged?.call(PlayerStatus.error);
      rethrow;
    }
  }

  Future<void> pause() => _player.pause();
  Future<void> resume() => _player.play();
  Future<void> seekTo(Duration position) => _player.seek(position);

  /// Jump to a specific queue index (used when the user clicks a track
  /// further down the same playlist — cheaper than reloading the
  /// whole queue).
  Future<void> seekToIndex(int index) async {
    if (!_concatInstalled) return;
    if (index < 0 || index >= _concat.length) return;
    try {
      await _player.seek(Duration.zero, index: index);
      // Restore volume in case we were mid fade-out.
      if (crossfadeMs > 0) {
        unawaited(restoreVolumeWithFadeIn(crossfadeMs));
      } else {
        try { await _player.setVolume(_userVolume); } catch (_) {}
      }
      unawaited(_player.play());
    } catch (e) {
      debugPrint('[AudioPlayer] seekToIndex($index) failed: $e');
    }
  }

  /// Skip to the next item in the queue — exposed to the notification
  /// "next" button by just_audio_background automatically.
  Future<void> seekToNext() async {
    if (_player.hasNext) {
      await _player.seekToNext();
    }
  }

  /// Skip back: if we're more than 3s into the current track, go back
  /// to its start instead (matches Spotify's behaviour).  Otherwise
  /// move to the previous queue item.
  Future<void> seekToPrevious() async {
    if (_player.position.inSeconds > 3 || !_player.hasPrevious) {
      await _player.seek(Duration.zero);
      return;
    }
    await _player.seekToPrevious();
  }

  /// Insert [track] at [index] in the concat.  The Player provider
  /// mirrors the same insertion into its [PlayerState.queue] list.
  Future<void> insertInQueue(int index, Track track) async {
    if (!_concatInstalled) return;
    final token = await _client.getToken();
    await _concat.insert(index, await _sourceFor(track, token));
  }

  /// Append [track] to the end of the queue.
  Future<void> appendToQueue(Track track) async {
    if (!_concatInstalled) return;
    final token = await _client.getToken();
    await _concat.add(await _sourceFor(track, token));
  }

  /// Remove the item at [index] from the queue.
  Future<void> removeAtFromQueue(int index) async {
    if (!_concatInstalled) return;
    if (index < 0 || index >= _concat.length) return;
    await _concat.removeAt(index);
  }

  /// Move the item at [from] to position [to] inside the queue.
  Future<void> moveInQueue(int from, int to) async {
    if (!_concatInstalled) return;
    await _concat.move(from, to);
  }

  /// Replace every item past [afterIndex] with the tracks in [newTail].
  /// Used by shuffle / clearRadioTail / reorder which can't be expressed
  /// cleanly as a small sequence of insert/move/remove operations.
  Future<void> replaceTailFromIndex(int afterIndex, List<Track> newTail) async {
    if (!_concatInstalled) return;
    // Drop everything past afterIndex in one logical pass.
    while (_concat.length > afterIndex + 1) {
      await _concat.removeAt(afterIndex + 1);
    }
    if (newTail.isEmpty) return;
    final token = await _client.getToken();
    final sources = await Future.wait(newTail.map((t) => _sourceFor(t, token)));
    await _concat.addAll(sources);
  }

  /// Replace the source at [index] with one built from [track] using a
  /// fresh JWT.  Used after the cache is invalidated ("Baixar novamente").
  Future<void> replaceAtInQueue(int index, Track track) async {
    if (!_concatInstalled) return;
    if (index < 0 || index >= _concat.length) return;
    final token = await _client.getToken();
    final src = await _sourceFor(track, token);
    // Concat doesn't expose replaceAt; remove + insert + adjust playback.
    final wasPlaying = _player.playing;
    await _concat.removeAt(index);
    await _concat.insert(index, src);
    if (_player.currentIndex == index) {
      try { await _player.seek(Duration.zero, index: index); } catch (_) {}
      if (wasPlaying) unawaited(_player.play());
    }
  }

  void setVolume(double volume) {
    _userVolume = volume.clamp(0.0, 1.0);
    _fadeGeneration++; // cancel any in-flight fade
    _player.setVolume(_userVolume);
  }

  /// Ramps the player volume from [from] to [to] in [durationMs].
  /// Cancels itself if another fade starts in the meantime.
  Future<void> _rampVolume(double from, double to, int durationMs) async {
    if (durationMs <= 0) {
      try { await _player.setVolume(to); } catch (_) {}
      return;
    }
    final gen = ++_fadeGeneration;
    const stepMs = 50;
    final steps = (durationMs / stepMs).round().clamp(1, 300);
    final delta = (to - from) / steps;
    var current = from;
    for (var i = 0; i < steps; i++) {
      if (gen != _fadeGeneration) return; // superseded
      current += delta;
      try {
        await _player.setVolume(current.clamp(0.0, 1.0));
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: stepMs));
    }
    if (gen == _fadeGeneration) {
      try { await _player.setVolume(to); } catch (_) {}
    }
  }

  /// Begins a fade-out on the currently playing track.  Used by the
  /// player provider when it detects the track is about to end and a
  /// crossfade is configured.  The next [seekToNext] resets the volume
  /// via a fresh [_rampVolume] (the new generation cancels this one).
  Future<void> fadeOut(int durationMs) {
    return _rampVolume(_userVolume, 0.0, durationMs);
  }

  /// Resets the volume to [_userVolume] with an optional fade-in.
  /// Called right after [seekToNext] / [seekToPrevious] so the next
  /// track doesn't inherit the fade-out volume from the previous one.
  Future<void> restoreVolumeWithFadeIn(int durationMs) async {
    if (durationMs <= 0) {
      try { await _player.setVolume(_userVolume); } catch (_) {}
      return;
    }
    try { await _player.setVolume(0); } catch (_) {}
    await _rampVolume(0.0, _userVolume, durationMs);
  }

  void dispose() => _player.dispose();

  Uri? _safeArtUri(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final uri = Uri.parse(raw);
      if (!uri.hasScheme || (uri.scheme != 'http' && uri.scheme != 'https')) {
        return null;
      }
      return uri;
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> _legacyTag(Track track) => {
    'id': track.id,
    'title': track.title,
    'artist': track.artist,
    'artUri': track.coverUrl,
  };
}
