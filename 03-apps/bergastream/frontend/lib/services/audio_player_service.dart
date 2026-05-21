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

      // Use MediaItem on native (required by just_audio_background to show
      // notification controls + survive backgrounding).  On web, use the
      // plain Map tag — just_audio_background isn't initialised there.
      final Object tag = kIsWeb
          ? _legacyTag(track)
          : MediaItem(
              id: track.id,
              title: track.title.isNotEmpty ? track.title : 'Faixa desconhecida',
              artist: track.artist,
              album: track.album,
              artUri: track.coverUrl != null ? Uri.tryParse(track.coverUrl!) : null,
              duration: track.durationMs != null
                  ? Duration(milliseconds: track.durationMs!)
                  : null,
            );

      await _player.setAudioSource(
        AudioSource.uri(
          Uri.parse(url),
          // Token no header para ExoPlayer (nativo); também vai na query string
          // para HTML5 audio (web) — ambos são aceitos pelo servidor.
          headers: token != null ? {'Authorization': 'Bearer $token'} : {},
          tag: tag,
        ),
      );
      await _player.play();
      debugPrint('[AudioPlayer] play() returned for "${track.title}"');
    } catch (e, st) {
      lastError = '$e';
      debugPrint('[AudioPlayer] play("${track.title}") failed: $e\n$st');
      onError?.call('$e');
      onStatusChanged?.call(PlayerStatus.error);
      rethrow;
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
