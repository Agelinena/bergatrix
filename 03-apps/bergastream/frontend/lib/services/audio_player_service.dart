import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../models/track.dart';
import '../core/api_client.dart';
import '../core/constants.dart';
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

  void Function(Duration)? onPositionChanged;
  void Function(Duration)? onDurationChanged;
  void Function(PlayerStatus)? onStatusChanged;
  void Function()? onTrackComplete;

  AudioPlayerService(this._client) {
    _player.positionStream.listen((pos) => onPositionChanged?.call(pos));
    _player.durationStream.listen((dur) => onDurationChanged?.call(dur ?? Duration.zero));
    _player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed) onTrackComplete?.call();
    });
    _player.playingStream.listen((playing) {
      onStatusChanged?.call(playing ? PlayerStatus.playing : PlayerStatus.paused);
    });
  }

  Future<void> play(Track track) async {
    final token = await _client.getToken();
    final url = _client.streamUrl(track.id, token: token);
    await _player.setAudioSource(
      AudioSource.uri(
        Uri.parse(url),
        headers: token != null ? {'Authorization': 'Bearer $token'} : {},
        tag: _trackTag(track),
      ),
    );
    await _player.play();
  }

  Future<void> pause() => _player.pause();
  Future<void> resume() => _player.play();
  Future<void> seekTo(Duration position) => _player.seek(position);
  void setVolume(double volume) => _player.setVolume(volume);

  void dispose() => _player.dispose();

  Map<String, dynamic> _trackTag(Track track) => {
    'id': track.id,
    'title': track.title,
    'artist': track.artist,
    'artUri': track.coverUrl,
  };
}
