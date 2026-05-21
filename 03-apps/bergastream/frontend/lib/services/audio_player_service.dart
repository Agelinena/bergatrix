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
    _player.positionStream.listen((pos) => onPositionChanged?.call(pos));
    _player.durationStream.listen((dur) => onDurationChanged?.call(dur ?? Duration.zero));
    _player.processingStateStream.listen((state) {
      debugPrint('[AudioPlayer] processingState=$state');
      if (state == ProcessingState.completed) onTrackComplete?.call();
    });
    _player.playingStream.listen((playing) {
      onStatusChanged?.call(playing ? PlayerStatus.playing : PlayerStatus.paused);
    });
    // Capture errors from the playback event stream so they don't get swallowed.
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
    // Errors specifically from setAudioSource / network failures.
    _player.playerStateStream.listen((s) {
      debugPrint('[AudioPlayer] playerState: playing=${s.playing} state=${s.processingState}');
    });
  }

  /// Configure the platform audio session.  Done lazily on first play so a
  /// failure doesn't crash the app at startup.  Without an explicit session,
  /// some Android devices refuse to grant audio focus and playback hangs
  /// at the "loading" state forever.
  Future<void> _ensureSession() async {
    if (_sessionConfigured) return;
    if (kIsWeb) {
      _sessionConfigured = true;
      return;
    }
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
      _sessionConfigured = true;
      debugPrint('[AudioPlayer] AudioSession configured (music profile)');
    } catch (e, st) {
      debugPrint('[AudioPlayer] AudioSession.configure failed: $e\n$st');
      // Not fatal — the player will still try to play.  But log it so we
      // know if this is the culprit.
    }
  }

  Future<void> play(Track track) async {
    lastError = null;
    try {
      await _ensureSession();
      await _player.stop();
      final token = await _client.getToken();
      final url = _client.streamUrl(track.id, token: token);
      debugPrint('[AudioPlayer] play "${track.title}" → $url (token=${token != null})');

      // Build the audio source.  The token is already in the URL's query
      // string (?token=...), so we do NOT also send it as a header.
      // ExoPlayer's HTTP datasource has been observed to hang
      // indefinitely when the `headers` map is non-empty on some
      // Android ROMs — the request never leaves the device, which
      // matches the reported symptom (server never sees GET /stream).
      //
      // Tag: MediaItem on native (drives just_audio_background's
      // notification), Map on web.
      final Object? tag = kIsWeb
          ? _legacyTag(track)
          : MediaItem(
              id: track.id,
              title: track.title.isNotEmpty ? track.title : 'Faixa desconhecida',
              artist: track.artist,
              album: track.album,
              // Skip artUri if not a clean http(s) URL — bad URIs have
              // tripped just_audio_background into a deadlock on some
              // devices, leaving the player stuck "loading".
              artUri: _safeArtUri(track.coverUrl),
              duration: track.durationMs != null
                  ? Duration(milliseconds: track.durationMs!)
                  : null,
            );

      final source = AudioSource.uri(Uri.parse(url), tag: tag);

      // Wrap setAudioSource + play in a timeout so the player never sits
      // in "loading" forever.  30 s is generous (longest legitimate first
      // byte we've seen is ~15 s during cold cache).
      try {
        await _player.setAudioSource(source).timeout(
          const Duration(seconds: 30),
          onTimeout: () => throw TimeoutException(
            'O player travou ao preparar o áudio (30s).\n'
            'O servidor não recebeu o GET /api/stream.\n'
            'URL: $url',
            const Duration(seconds: 30),
          ),
        );
        await _player.play();
        debugPrint('[AudioPlayer] play() returned for "${track.title}"');
      } on TimeoutException catch (e) {
        debugPrint('[AudioPlayer] setAudioSource TIMEOUT for "${track.title}": ${e.message}');
        throw Exception(e.message);
      }
    } catch (e, st) {
      lastError = '$e';
      debugPrint('[AudioPlayer] play("${track.title}") failed: $e\n$st');
      onError?.call('$e');
      onStatusChanged?.call(PlayerStatus.error);
      rethrow;
    }
  }

  /// Returns a safe Uri for the MediaItem.artUri field, or null.
  /// Filters out empty strings, relative paths, and anything that won't
  /// parse cleanly — bad URIs can hang just_audio_background.
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

  Future<void> pause() => _player.pause();
  Future<void> resume() => _player.play();
  Future<void> seekTo(Duration position) => _player.seek(position);
  void setVolume(double volume) => _player.setVolume(volume);

  void dispose() => _player.dispose();

  /// Web tag (just_audio_background not active there).
  Map<String, dynamic> _legacyTag(Track track) => {
    'id': track.id,
    'title': track.title,
    'artist': track.artist,
    'artUri': track.coverUrl,
  };
}
