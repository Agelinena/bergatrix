import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../models/track.dart';
import '../services/audio_player_service.dart';
import '../core/api_client.dart';
import 'playback_settings_provider.dart';
import 'sync_provider.dart';

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
  /// Mensagem do último erro do player (exibida em SnackBar quando o
  /// status muda para error).
  final String? lastError;

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
    this.lastError,
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
    String? lastError,
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
    lastError: lastError ?? this.lastError,
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

  /// True between the moment we schedule the crossfade advance and the
  /// moment the next [play] takes over.  Prevents [_handleTrackComplete]
  /// from firing a second [next] when the natural end-of-track event
  /// arrives during the fade.
  bool _crossfadeInFlight = false;
  Timer? _crossfadeAdvanceTimer;

  @override
  PlayerState build() {
    _service = ref.read(audioPlayerServiceProvider);
    _service.onPositionChanged = (pos) {
      state = state.copyWith(position: pos);
      _maybeStartCrossfade();
    };
    _service.onDurationChanged = (dur) {
      if (dur > Duration.zero) state = state.copyWith(duration: dur);
    };
    _service.onStatusChanged = (s) {
      state = state.copyWith(status: s);
      _publishSync();
    };
    _service.onTrackComplete = () => _handleTrackComplete();
    _service.onCurrentIndexChanged = (idx) => _onCurrentIndexChanged(idx);
    _service.onError = (msg) {
      state = state.copyWith(status: PlayerStatus.error, lastError: msg);
    };

    // Push the persisted crossfade preference into the audio service
    // and keep them in sync.  The listener fires whenever the user
    // tweaks the slider in Settings.
    final initial = ref.read(playbackSettingsProvider).crossfadeMs;
    _service.crossfadeMs = initial;
    ref.listen<PlaybackSettings>(playbackSettingsProvider, (prev, next) {
      _service.crossfadeMs = next.crossfadeMs;
    });

    // Wire remote-control commands from sync_provider.  Other devices
    // can play/pause/next/etc this device's player without re-typing.
    final sync = ref.read(syncProvider.notifier);
    sync.setRemoteCommandHandler((command, args) {
      debugPrint('[Player] remote command: $command $args');
      switch (command) {
        case 'play':
          if (!state.isPlaying) resume();
        case 'pause':
          if (state.isPlaying) pause();
        case 'toggle':
          togglePlayPause();
        case 'next':
          next();
        case 'previous':
          previous();
        case 'seek':
          final ms = (args['position_ms'] as num?)?.toInt();
          if (ms != null) seekTo(Duration(milliseconds: ms));
      }
    });

    return const PlayerState();
  }

  /// Pushes the current player snapshot to peer devices via sync_provider.
  /// Called after every meaningful state transition.  Throttle is on the
  /// server side — broadcasts are cheap.
  void _publishSync() {
    try {
      final t = state.currentTrack;
      ref.read(syncProvider.notifier).publishState({
        if (t != null) 'track': t.toJson(),
        'position_ms': state.position.inMilliseconds,
        'duration_ms': state.duration.inMilliseconds,
        'playing': state.isPlaying,
        'queue': state.queue.map((q) => q.toJson()).toList(),
        'queue_index': state.queueIndex,
        'shuffle': state.shuffle,
        'repeat': state.repeat.name,
      });
    } catch (_) {/* ignore — sync may not be connected yet */}
  }

  Future<void> play(Track track, {List<Track> queue = const []}) async {
    // A new play() supersedes any pending crossfade timer.
    _crossfadeAdvanceTimer?.cancel();
    _crossfadeAdvanceTimer = null;
    _crossfadeInFlight = false;

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
    final clampedIdx = idx < 0 ? 0 : idx;

    // If this is the same queue, just seek to the new index inside the
    // existing concat — avoids tearing down the foreground service on
    // Android.  Otherwise we hand a brand-new queue to the service.
    final sameQueue = _queuesAreEquivalent(state.queue, q);

    state = state.copyWith(
      currentTrack: track,
      queue: q,
      queueIndex: clampedIdx,
      status: PlayerStatus.loading,
      position: Duration.zero,
      duration: track.durationMs != null && track.durationMs! > 0
          ? Duration(milliseconds: track.durationMs!)
          : Duration.zero,
      manualQueueAhead: 0,
    );
    _prefetchUpcoming();

    try {
      if (sameQueue) {
        // Same playlist, different item → in-concat seek.  Keeps the
        // foreground service alive (Android) and is much cheaper.
        await _service.seekToIndex(clampedIdx);
      } else {
        await _service.playQueue(q, clampedIdx);
      }
    } catch (e) {
      state = state.copyWith(
        status: PlayerStatus.error,
        lastError: state.lastError ?? '$e',
      );
    }
  }

  bool _queuesAreEquivalent(List<Track> a, List<Track> b) {
    if (a.length != b.length || a.isEmpty) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id) return false;
    }
    return true;
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
    if (state.queueIndex + 1 >= state.queue.length) return;
    // Just ask the player to advance; the onCurrentIndexChanged
    // listener will update state.queueIndex / currentTrack /
    // manualQueueAhead consistently.
    await _service.seekToNext();
  }

  Future<void> previous() async {
    if (state.position.inSeconds > 3) {
      await seekTo(Duration.zero);
      return;
    }
    if (state.queueIndex <= 0) {
      await seekTo(Duration.zero);
      return;
    }
    await _service.seekToPrevious();
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
      final newQueue = [...before, ...after];
      state = state.copyWith(queue: newQueue, shuffle: true);
      // Mirror the reordering into the audio concat so skipToNext/Prev
      // (incl. the notification buttons) follow the same sequence.
      _service.replaceTailFromIndex(
        state.queueIndex,
        newQueue.sublist(state.queueIndex + 1),
      );
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
    // Mirror into the audio concat so the notification's "next" button
    // can reach this track without re-loading the queue.
    _service.appendToQueue(track);
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
    // Mirror in the audio concat: drop everything past keepUntil-1.
    _service.replaceTailFromIndex(keepUntil - 1, const []);
  }

  /// Insere a faixa logo após o bloco de músicas já adicionadas manualmente,
  /// garantindo ordem FIFO para múltiplos "Adicionar à fila" consecutivos.
  ///
  /// Exemplo com [manualQueueAhead] = 2:
  ///   [Atual | ManualA | ManualB | Rádio1 | Rádio2]
  ///   → inserir ManualC na posição queueIndex+1+2 = queueIndex+3
  ///   → [Atual | ManualA | ManualB | ManualC | Rádio1 | Rádio2]
  ///
  /// Também dispara o prefetch da track no backend.  Sem isso, "Tocar a
  /// seguir" inseria a faixa na fila do player mas o backend não sabia
  /// que precisava baixá-la — só descobria quando o player avançava
  /// e disparava o download on-demand (latência alta no primeiro byte).
  void insertNextInQueue(Track track) {
    final insertAt = (state.queueIndex + 1 + state.manualQueueAhead)
        .clamp(0, state.queue.length);
    final newQueue = [...state.queue];
    newQueue.insert(insertAt, track);
    state = state.copyWith(
      queue: newQueue,
      manualQueueAhead: state.manualQueueAhead + 1,
    );
    // Mirror into audio concat at the same index so seekToNext picks
    // it up without us having to reload the queue.
    _service.insertInQueue(insertAt, track);
    // Fire-and-forget prefetch — passa o Track completo para auto-registro
    // no backend caso a faixa ainda não esteja no DB.
    try {
      ref.read(apiClientProvider).prefetchTracks(
        [track.id],
        tracks: [track],
      );
    } catch (_) {}
  }

  /// Remove a primeira ocorrência de [trackId] da fila — usado pelo
  /// gesto de "arrastar para esquerda" na busca, que pode tirar uma
  /// faixa que o usuário tinha adicionado por engano.
  ///
  /// Não remove a track atualmente tocando (item em [queueIndex]),
  /// somente itens à frente.  Retorna `true` se algo foi removido.
  bool removeFromQueueById(String trackId) {
    final queue = state.queue;
    // Procura SÓ no trecho pós-atual para não interromper a track tocando.
    for (var i = state.queueIndex + 1; i < queue.length; i++) {
      if (queue[i].id == trackId) {
        final newQueue = [...queue]..removeAt(i);
        // Decrementa manualQueueAhead se o item removido estava na faixa
        // manual (i.e. logo após o atual, dentro do bloco manual).
        final manualEnd = state.queueIndex + state.manualQueueAhead;
        final newManual = (i <= manualEnd)
            ? (state.manualQueueAhead - 1).clamp(0, state.manualQueueAhead)
            : state.manualQueueAhead;
        state = state.copyWith(queue: newQueue, manualQueueAhead: newManual);
        // Mirror in the audio concat — same index because the
        // service and the provider keep parallel lists.
        _service.removeAtFromQueue(i);
        return true;
      }
    }
    return false;
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
    _service.moveInQueue(from, to);
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

  /// Fires only when the ConcatenatingAudioSource is fully exhausted
  /// (no more "next" inside the concat) — so this is effectively the
  /// "last track of the queue finished" hook.  Mid-queue transitions
  /// are handled by [_onCurrentIndexChanged] instead.
  void _handleTrackComplete() {
    if (state.currentTrack != null) {
      _recordPlay(state.currentTrack!, state.duration, completed: true);
    }
    if (state.repeat == RepeatMode.one) {
      _service.seekTo(Duration.zero);
      _service.resume();
      return;
    }
    // No more tracks — playback stops naturally.  The queue panel can
    // still show what was last on, just paused at the end.
  }

  /// Called by the audio service whenever the underlying player moves
  /// to a different item in the concat — either via seekToNext/Prev
  /// (manual buttons, notification controls, crossfade advance) or
  /// because the previous track ended and ExoPlayer auto-advanced.
  /// We mirror the change into [PlayerState] so the UI stays in sync.
  void _onCurrentIndexChanged(int newIdx) {
    if (newIdx < 0 || newIdx >= state.queue.length) return;
    if (newIdx == state.queueIndex) return;
    final advanced = newIdx - state.queueIndex;
    // Record play for the track we're leaving (if we moved forward).
    if (advanced > 0 && state.currentTrack != null) {
      _recordPlay(state.currentTrack!, state.duration, completed: true);
    }
    final newTrack = state.queue[newIdx];
    // Decrement the manual-queue counter by how many manual slots we
    // crossed.  If we jumped past everything manual, clamp to 0.
    int newManual = state.manualQueueAhead;
    if (advanced > 0) {
      newManual = (state.manualQueueAhead - advanced)
          .clamp(0, state.manualQueueAhead);
    }
    _crossfadeAdvanceTimer?.cancel();
    _crossfadeAdvanceTimer = null;
    _crossfadeInFlight = false;
    state = state.copyWith(
      queueIndex: newIdx,
      currentTrack: newTrack,
      position: Duration.zero,
      duration: (newTrack.durationMs != null && newTrack.durationMs! > 0)
          ? Duration(milliseconds: newTrack.durationMs!)
          : Duration.zero,
      manualQueueAhead: newManual,
    );
    _prefetchUpcoming();
    // If we were in the middle of a fade-out, restore the volume on
    // the new item so it doesn't start silent.
    if (_service.crossfadeMs > 0) {
      _service.restoreVolumeWithFadeIn(_service.crossfadeMs);
    }
  }

  /// Called on every position update.  When crossfade is enabled,
  /// computes how much time is left on the current track and — if
  /// it fits within the crossfade window AND we have a next track —
  /// starts the fade-out and schedules the next [play] just before
  /// the current track ends, so the two ramps overlap.
  void _maybeStartCrossfade() {
    final fade = _service.crossfadeMs;
    if (fade <= 0) return;
    if (_crossfadeInFlight) return;
    if (state.repeat == RepeatMode.one) return;
    final dur = state.duration.inMilliseconds;
    final pos = state.position.inMilliseconds;
    if (dur <= 0 || pos <= 0) return;
    if (state.queueIndex + 1 >= state.queue.length) return;
    final remaining = dur - pos;
    // Guard against the very first ticks (sometimes duration < position
    // briefly) and against very short remaining values that don't
    // benefit from a fade.
    if (remaining <= 0 || remaining > fade) return;

    _crossfadeInFlight = true;
    debugPrint('[Player] crossfade start: remaining=${remaining}ms fade=${fade}ms');
    // Fade out the current track over the remaining duration.
    _service.fadeOut(remaining);
    // Schedule the next track slightly before the natural end so the
    // ramps overlap.  Half the remaining time is a reasonable midpoint
    // — too early and we cut too much of the current track; too late
    // and there's an audible gap.
    final advanceIn = (remaining / 2).clamp(150, fade.toDouble()).toInt();
    _crossfadeAdvanceTimer?.cancel();
    _crossfadeAdvanceTimer = Timer(Duration(milliseconds: advanceIn), () {
      if (!_crossfadeInFlight) return;
      _advanceForCrossfade();
    });
  }

  Future<void> _advanceForCrossfade() async {
    if (state.queueIndex + 1 >= state.queue.length) {
      _crossfadeInFlight = false;
      return;
    }
    // Just advance — the listener will record play, update state and
    // ramp the new volume back up.
    await _service.seekToNext();
  }

  void _recordPlay(Track track, Duration position, {bool completed = false}) {
    try {
      ref.read(apiClientProvider).recordPlay(track.id, position.inMilliseconds, completed: completed);
    } catch (_) {}
  }
}
