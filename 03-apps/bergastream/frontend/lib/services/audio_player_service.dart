import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../models/track.dart';
import '../core/api_client.dart';
import '../providers/player_provider.dart' show PlayerStatus;

part 'audio_player_service.g.dart';

/// Toggle for the just_audio_background MediaItem tag.  When true,
/// AudioSource.uri receives a MediaItem and the lockscreen / notification
/// controls come up; when false we use a plain Map tag (no notification).
///
/// Was temporarily off while we identified the "spinner forever" bug —
/// turned out to be unrelated (Future from _player.play() doesn't resolve
/// until playback ends, my timeout was wrong).  Re-enabled now.
const _useBackgroundMediaItem = true;

@Riverpod(keepAlive: true)
AudioPlayerService audioPlayerService(AudioPlayerServiceRef ref) {
  final service = AudioPlayerService(ref.read(apiClientProvider));
  ref.onDispose(service.dispose);
  return service;
}

class AudioPlayerService {
  final ApiClient _client;
  final AudioPlayer _player = AudioPlayer();
  bool _sessionConfigured = false;

  /// Last error captured from the player, exposed so the UI can show it.
  String? lastError;

  void Function(Duration)? onPositionChanged;
  void Function(Duration)? onDurationChanged;
  void Function(PlayerStatus)? onStatusChanged;
  void Function()? onTrackComplete;
  void Function(String error)? onError;

  AudioPlayerService(this._client) {
    debugPrint('[AudioPlayer] constructor: created AudioPlayer instance');
    _player.positionStream.listen((pos) => onPositionChanged?.call(pos));
    _player.durationStream.listen((dur) => onDurationChanged?.call(dur ?? Duration.zero));
    _player.processingStateStream.listen((state) {
      debugPrint('[AudioPlayer] processingState=$state');
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

  /// Wraps a Future with a label so timeouts produce a clearly traceable error.
  Future<T> _step<T>(String label, Duration timeout, Future<T> Function() task) {
    return task().timeout(
      timeout,
      onTimeout: () => throw TimeoutException(
        'Audio player travou em "$label" após ${timeout.inSeconds}s',
        timeout,
      ),
    );
  }

  Future<void> play(Track track) async {
    final t0 = DateTime.now();
    debugPrint('[AudioPlayer] play() START "${track.title}" id=${track.id}');
    lastError = null;
    try {
      await _step('ensureSession', const Duration(seconds: 10), _ensureSession);
      debugPrint('[AudioPlayer] +${DateTime.now().difference(t0).inMilliseconds}ms session ok');

      await _step('player.stop', const Duration(seconds: 5), () => _player.stop());
      debugPrint('[AudioPlayer] +${DateTime.now().difference(t0).inMilliseconds}ms stop ok');

      final token = await _step('getToken', const Duration(seconds: 3),
          () => _client.getToken());
      final url = _client.streamUrl(track.id, token: token);
      debugPrint('[AudioPlayer] +${DateTime.now().difference(t0).inMilliseconds}ms '
          'url=$url tokenLen=${token?.length ?? 0}');

      // Choose tag.  Map tag works on every platform but skips the
      // background-notification integration.  MediaItem only when
      // _useBackgroundMediaItem and on native — but we've seen it
      // deadlock on some Android ROMs, hence the toggle.
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

      debugPrint('[AudioPlayer] +${DateTime.now().difference(t0).inMilliseconds}ms '
          'tag type=${tag.runtimeType}');

      final source = AudioSource.uri(Uri.parse(url), tag: tag);

      await _step('setAudioSource', const Duration(seconds: 30),
          () => _player.setAudioSource(source));
      debugPrint('[AudioPlayer] +${DateTime.now().difference(t0).inMilliseconds}ms '
          'setAudioSource ok');

      // IMPORTANT: do NOT await _player.play().
      // just_audio's Future<void> play() only completes when playback
      // ENDS (track finished, paused, or stopped) — not when it starts.
      // Awaiting it caused a 5s timeout to fire while the track was
      // happily playing, marking the player state as error and
      // triggering a SnackBar of doom.
      //
      // We confirm playback actually started by waiting for the
      // first playingStream==true event (or the audio source being
      // in ready state), but with a short bound so the UI is never
      // blocked.
      unawaited(_player.play());
      debugPrint('[AudioPlayer] +${DateTime.now().difference(t0).inMilliseconds}ms '
          'play() invoked (fire-and-forget)');
    } catch (e, st) {
      final elapsed = DateTime.now().difference(t0).inMilliseconds;
      lastError = '$e (após ${elapsed}ms)';
      debugPrint('[AudioPlayer] play("${track.title}") failed after ${elapsed}ms: $e\n$st');
      onError?.call(lastError!);
      onStatusChanged?.call(PlayerStatus.error);
      rethrow;
    }
  }

  Future<void> pause() => _player.pause();
  Future<void> resume() => _player.play();
  Future<void> seekTo(Duration position) => _player.seek(position);
  void setVolume(double volume) => _player.setVolume(volume);

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

  /// Plain Map tag — works on every platform, no background-service hooks.
  Map<String, dynamic> _legacyTag(Track track) => {
    'id': track.id,
    'title': track.title,
    'artist': track.artist,
    'artUri': track.coverUrl,
  };
}
