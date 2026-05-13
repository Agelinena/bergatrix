import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../models/track.dart';
import '../services/audio_player_service.dart';

part 'player_provider.g.dart';

enum RepeatMode { none, one, all }
enum PlayerStatus { idle, loading, playing, paused, error }

class PlayerState {
  final Track? currentTrack;
  final List<Track> queue;
  final int queueIndex;
  final PlayerStatus status;
  final Duration position;
  final Duration duration;
  final double volume;
  final bool shuffle;
  final RepeatMode repeat;

  const PlayerState({
    this.currentTrack,
    this.queue = const [],
    this.queueIndex = 0,
    this.status = PlayerStatus.idle,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.volume = 1.0,
    this.shuffle = false,
    this.repeat = RepeatMode.none,
  });

  PlayerState copyWith({
    Track? currentTrack,
    List<Track>? queue,
    int? queueIndex,
    PlayerStatus? status,
    Duration? position,
    Duration? duration,
    double? volume,
    bool? shuffle,
    RepeatMode? repeat,
  }) => PlayerState(
    currentTrack: currentTrack ?? this.currentTrack,
    queue: queue ?? this.queue,
    queueIndex: queueIndex ?? this.queueIndex,
    status: status ?? this.status,
    position: position ?? this.position,
    duration: duration ?? this.duration,
    volume: volume ?? this.volume,
    shuffle: shuffle ?? this.shuffle,
    repeat: repeat ?? this.repeat,
  );

  bool get isPlaying => status == PlayerStatus.playing;
  bool get hasTrack => currentTrack != null;
  double get progress => duration.inMilliseconds > 0
    ? position.inMilliseconds / duration.inMilliseconds
    : 0.0;
}

@Riverpod(keepAlive: true)
class Player extends _$Player {
  late final AudioPlayerService _service;

  @override
  PlayerState build() {
    _service = ref.read(audioPlayerServiceProvider);
    _service.onPositionChanged = (pos) => state = state.copyWith(position: pos);
    _service.onDurationChanged = (dur) => state = state.copyWith(duration: dur);
    _service.onStatusChanged = (s) => state = state.copyWith(status: s);
    _service.onTrackComplete = () => _handleTrackComplete();
    return const PlayerState();
  }

  Future<void> play(Track track, {List<Track> queue = const []}) async {
    final q = queue.isEmpty ? [track] : queue;
    final idx = q.indexWhere((t) => t.id == track.id);
    state = state.copyWith(
      currentTrack: track,
      queue: q,
      queueIndex: idx < 0 ? 0 : idx,
      status: PlayerStatus.loading,
    );
    await _service.play(track);
  }

  Future<void> pause() async {
    await _service.pause();
    state = state.copyWith(status: PlayerStatus.paused);
  }

  Future<void> resume() async {
    await _service.resume();
    state = state.copyWith(status: PlayerStatus.playing);
  }

  Future<void> togglePlayPause() async {
    if (state.isPlaying) {
      await pause();
    } else {
      await resume();
    }
  }

  Future<void> seekTo(Duration position) async {
    await _service.seekTo(position);
    state = state.copyWith(position: position);
  }

  Future<void> next() async {
    final nextIdx = state.queueIndex + 1;
    if (nextIdx >= state.queue.length) return;
    await play(state.queue[nextIdx], queue: state.queue);
    state = state.copyWith(queueIndex: nextIdx);
  }

  Future<void> previous() async {
    if (state.position.inSeconds > 3) {
      await seekTo(Duration.zero);
      return;
    }
    final prevIdx = state.queueIndex - 1;
    if (prevIdx < 0) return;
    await play(state.queue[prevIdx], queue: state.queue);
    state = state.copyWith(queueIndex: prevIdx);
  }

  void setVolume(double volume) {
    _service.setVolume(volume);
    state = state.copyWith(volume: volume);
  }

  void toggleShuffle() => state = state.copyWith(shuffle: !state.shuffle);

  void toggleRepeat() {
    final next = RepeatMode.values[(state.repeat.index + 1) % RepeatMode.values.length];
    state = state.copyWith(repeat: next);
  }

  void addToQueue(Track track) {
    state = state.copyWith(queue: [...state.queue, track]);
  }

  void _handleTrackComplete() {
    if (state.repeat == RepeatMode.one) {
      _service.seekTo(Duration.zero);
      _service.resume();
      return;
    }
    next();
  }
}
