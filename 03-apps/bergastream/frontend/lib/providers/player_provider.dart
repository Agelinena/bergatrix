import 'dart:math';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../models/track.dart';
import '../services/audio_player_service.dart';
import '../core/api_client.dart';

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
    _service.onDurationChanged = (dur) {
      // Only update if audio player reports a real duration; keep metadata
      // pre-fill when streaming in follow-file mode (just_audio reports 0).
      if (dur > Duration.zero) state = state.copyWith(duration: dur);
    };
    _service.onStatusChanged = (s) => state = state.copyWith(status: s);
    _service.onTrackComplete = () => _handleTrackComplete();
    return const PlayerState();
  }

  Future<void> play(Track track, {List<Track> queue = const []}) async {
    // Register in DB before streaming — stream endpoint returns 404 if track unknown
    try {
      await ref.read(apiClientProvider).registerTrack(track.toJson());
    } catch (_) {}

    // Record previous track before switching (if played for more than 5s)
    if (state.hasTrack && state.position.inSeconds > 5) {
      _recordPlay(state.currentTrack!, state.position, completed: false);
    }

    final q = queue.isEmpty ? [track] : queue;
    final idx = q.indexWhere((t) => t.id == track.id);
    state = state.copyWith(
      currentTrack: track,
      queue: q,
      queueIndex: idx < 0 ? 0 : idx,
      status: PlayerStatus.loading,
      position: Duration.zero,
      // Pre-fill duration from metadata so progress bar works in follow-file mode
      duration: track.durationMs != null && track.durationMs! > 0
          ? Duration(milliseconds: track.durationMs!)
          : Duration.zero,
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
    if (state.queue.isEmpty) return;
    int nextIdx;
    if (state.shuffle) {
      final candidates = List.generate(state.queue.length, (i) => i)
          .where((i) => i != state.queueIndex)
          .toList();
      if (candidates.isEmpty) return;
      nextIdx = candidates[Random().nextInt(candidates.length)];
    } else {
      nextIdx = state.queueIndex + 1;
      if (nextIdx >= state.queue.length) return;
    }
    await play(state.queue[nextIdx], queue: state.queue);
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
    if (state.currentTrack != null) {
      _recordPlay(state.currentTrack!, state.duration, completed: true);
    }
    if (state.repeat == RepeatMode.one) {
      _service.seekTo(Duration.zero);
      _service.resume();
      return;
    }
    next();
  }

  void _recordPlay(Track track, Duration position, {bool completed = false}) {
    try {
      ref.read(apiClientProvider).recordPlay(track.id, position.inMilliseconds, completed: completed);
    } catch (_) {}
  }
}
