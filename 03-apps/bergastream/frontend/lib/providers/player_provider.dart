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
  /// Quantas faixas foram adicionadas manualmente logo após a atual.
  /// Garante que adds manuais consecutivos empilhem em ordem FIFO:
  /// [Atual | ManualA | ManualB | ManualC | Rádio1 | Rádio2 ...]
  final int manualQueueAhead;

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
    this.manualQueueAhead = 0,
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
    int? manualQueueAhead,
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
    manualQueueAhead: manualQueueAhead ?? this.manualQueueAhead,
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
    // Fire-and-forget: awaiting a network call here breaks the browser's user-gesture
    // context, causing audio.play() to be rejected by the autoplay policy on web.
    // The stream endpoint retries the track lookup for up to 1 s to handle the race.
    ref.read(apiClientProvider).registerTrack(track.toJson()).ignore();

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
      manualQueueAhead: 0,
    );
    // Kick off background prefetch for upcoming tracks immediately
    _prefetchUpcoming();
    try {
      await _service.play(track);
    } catch (e) {
      state = state.copyWith(status: PlayerStatus.error);
    }
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
    // Decrementa o contador de manuais ao avançar: se havia músicas manuais
    // na frente, a que vai tocar agora era a primeira delas.
    final newManual = (state.manualQueueAhead - 1).clamp(0, state.manualQueueAhead);
    await play(state.queue[nextIdx], queue: state.queue);
    // play() reseta manualQueueAhead para 0; re-aplica o valor decrementado.
    state = state.copyWith(manualQueueAhead: newManual);
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

  void toggleShuffle() {
    if (!state.shuffle && state.queue.length > 1) {
      // Shuffle the portion of the queue that comes after the current track
      final before = state.queue.sublist(0, state.queueIndex + 1);
      final after = [...state.queue.sublist(state.queueIndex + 1)]..shuffle(Random());
      state = state.copyWith(queue: [...before, ...after], shuffle: true);
    } else {
      state = state.copyWith(shuffle: false);
    }
  }

  void toggleRepeat() {
    final next = RepeatMode.values[(state.repeat.index + 1) % RepeatMode.values.length];
    state = state.copyWith(repeat: next);
  }

  /// Adiciona ao FINAL da fila — usado pelo rádio para preservar a ordem das sugestões.
  void addToQueue(Track track) {
    state = state.copyWith(queue: [...state.queue, track]);
    // Prefetch is NOT triggered here — the radio provider calls prefetchTracks()
    // in bulk after all tracks are added. Calling it per-add caused 20 redundant
    // prefetch requests for every radio activation.
  }

  /// Limpa o "tail" da fila — usado pelo RadioQueueNotifier quando o seed
  /// muda, para não misturar a rádio antiga com a nova.
  ///
  /// Mantém:
  ///   * a track atual e tudo antes dela (histórico)
  ///   * as próximas [manualQueueAhead] tracks (adicionadas manualmente
  ///     pelo usuário via "Tocar a seguir" / "Adicionar à fila")
  /// Remove o resto, que veio de uma rádio anterior.
  void clearRadioTail() {
    final keepUntil =
        (state.queueIndex + 1 + state.manualQueueAhead).clamp(0, state.queue.length);
    if (keepUntil >= state.queue.length) return; // nada a remover
    state = state.copyWith(queue: state.queue.sublist(0, keepUntil));
  }

  /// Insere a faixa logo após o bloco de músicas já adicionadas manualmente,
  /// garantindo ordem FIFO para múltiplos "Adicionar à fila" consecutivos.
  ///
  /// Exemplo com [manualQueueAhead] = 2:
  ///   [Atual | ManualA | ManualB | Rádio1 | Rádio2]
  ///   → inserir ManualC na posição queueIndex+1+2 = queueIndex+3
  ///   → [Atual | ManualA | ManualB | ManualC | Rádio1 | Rádio2]
  void insertNextInQueue(Track track) {
    final insertAt = (state.queueIndex + 1 + state.manualQueueAhead)
        .clamp(0, state.queue.length);
    final newQueue = [...state.queue];
    newQueue.insert(insertAt, track);
    state = state.copyWith(
      queue: newQueue,
      manualQueueAhead: state.manualQueueAhead + 1,
    );
  }

  /// Reordena a fila de "próximas" músicas (itens após o atual).
  /// [oldIndex] e [newIndex] são relativos ao trecho pós-atual.
  void reorderQueue(int oldIndex, int newIndex) {
    final base = state.queueIndex + 1;
    final queue = [...state.queue];
    final from = base + oldIndex;
    var to = base + newIndex;
    // ReorderableListView já ajusta newIndex quando move para baixo,
    // mas aplicamos a correção padrão do Flutter.
    if (to > from) to -= 1;
    if (from < 0 || from >= queue.length || to < 0 || to >= queue.length) return;
    final item = queue.removeAt(from);
    queue.insert(to, item);
    state = state.copyWith(queue: queue);
  }

  /// Prefetches the next [_prefetchAhead] tracks from the current queue position
  /// so they are cached before the player needs them.
  static const _prefetchAhead = 5;

  void _prefetchUpcoming() {
    final upcomingTracks = state.queue
        .skip(state.queueIndex + 1)
        .take(_prefetchAhead)
        .toList();
    if (upcomingTracks.isEmpty) return;
    try {
      // Send full Track payload so backend auto-registers any tracks that
      // aren't in the DB yet (radio suggestions, etc.).
      ref.read(apiClientProvider).prefetchTracks(
        upcomingTracks.map((t) => t.id).toList(),
        tracks: upcomingTracks,
      );
    } catch (_) {}
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
