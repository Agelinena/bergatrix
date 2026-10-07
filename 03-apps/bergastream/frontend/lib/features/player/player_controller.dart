import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_error.dart';
import '../../data/local/database.dart';
import '../../data/models/search_result.dart';
import '../../data/repositories/playback_repository.dart';
import '../auth/session.dart';
import '../home/home_providers.dart';
import 'audio_engine.dart';
import 'media_notification.dart';
import 'play_queue.dart';

/// Estado do que está tocando.
enum PlaybackStatus { parado, preparando, tocando, pausado, erro }

class PlayerState {
  const PlayerState({
    this.current,
    this.status = PlaybackStatus.parado,
    this.shuffle = false,
    this.repeat = PlayerRepeat.desligado,
    this.manual = const [],
    this.upNext = const [],
    this.context,
    this.duration,
    this.message,
  });

  final QueueItem? current;
  final PlaybackStatus status;
  final bool shuffle;
  final PlayerRepeat repeat;

  /// Sua fila (manual).
  final List<QueueItem> manual;

  /// A seguir da lista que está tocando.
  final List<QueueItem> upNext;

  /// De onde a música está tocando ("Busca", nome da playlist...).
  final String? context;

  final Duration? duration;

  /// Aviso para mostrar uma vez (erro ao tocar, modo de repetição...).
  final PlayerMessage? message;

  bool get isPlaying => status == PlaybackStatus.tocando;
  bool get isPreparing => status == PlaybackStatus.preparando;
}

/// Aviso rápido do player. Cada um tem um [id] novo para a UI não repetir.
class PlayerMessage {
  PlayerMessage(this.text) : id = _ids++;

  static int _ids = 0;
  final int id;
  final String text;
}

/// Tempos do player (os testes zeram).
class PlayerTimings {
  const PlayerTimings({
    this.pollInterval = const Duration(milliseconds: 1500),
    this.prepareTimeout = const Duration(minutes: 3),
  });

  final Duration pollInterval;
  final Duration prepareTimeout;
}

final playerTimingsProvider = Provider<PlayerTimings>(
  (ref) => const PlayerTimings(),
);

/// Quem registra as reproduções no histórico (Seção 7.4): servidor, ou o
/// banco local para enviar depois.
typedef PlayRecorder = void Function(SearchResult track);

final playRecorderProvider = Provider<PlayRecorder>((ref) {
  final send = ref.watch(playRecorderServiceProvider);
  return (track) => unawaited(send(track));
});

/// Posição atual da faixa (separada do estado para não redesenhar tudo).
final playerPositionProvider = StreamProvider<Duration>(
  (ref) => ref.watch(audioEngineProvider).positionStream,
);

final playerProvider = NotifierProvider<PlayerController, PlayerState>(
  PlayerController.new,
);

class PlayerController extends Notifier<PlayerState> {
  final _queue = PlayQueue();
  int _generation = 0;
  Duration? _duration;
  bool _counted = false;
  final _subscriptions = <StreamSubscription<Object?>>[];

  AudioEngine get _engine => ref.read(audioEngineProvider);
  PlaybackRepository get _repository => ref.read(playbackRepositoryProvider);
  BergaAudioHandler? get _notification => ref.read(mediaNotificationProvider);

  static const notPlayable = 'Não foi possível tocar esta música.';
  static const notDownloaded = 'Esta música não está baixada.';

  @override
  PlayerState build() {
    final engine = ref.watch(audioEngineProvider);
    _subscriptions
      ..add(engine.completedStream.listen((_) => _onCompleted()))
      ..add(engine.durationStream.listen(_onDuration))
      ..add(engine.positionStream.listen(_onPosition));
    _notification?.onCommand = _onNotificationCommand;
    ref.onDispose(() {
      for (final s in _subscriptions) {
        s.cancel();
      }
    });
    return const PlayerState();
  }

  /// Toca [tracks] a partir de [index] (a fila automática vira o resto da
  /// lista). [context] aparece em "Tocando de …".
  Future<void> playList(
    List<SearchResult> tracks,
    int index, {
    required String context,
  }) async {
    _queue.playList(tracks, index);
    _context = context;
    await _loadCurrent();
  }

  String? _context;

  /// "Adicionar à fila". Se nada estiver tocando, começa por ela.
  Future<void> addToQueue(SearchResult track) async {
    _queue.add(track);
    if (state.current == null) {
      _queue.startFromManual();
      _context = 'Sua fila';
      await _loadCurrent();
    } else {
      _publish();
    }
  }

  Future<void> togglePlay() async {
    switch (state.status) {
      case PlaybackStatus.tocando:
        await _engine.pause();
        _publish(status: PlaybackStatus.pausado);
      case PlaybackStatus.pausado:
        _engine.play();
        _publish(status: PlaybackStatus.tocando);
      case PlaybackStatus.parado || PlaybackStatus.erro:
        if (_queue.current != null) await _loadCurrent();
      case PlaybackStatus.preparando:
        break;
    }
  }

  Future<void> next() => _advance(ended: false);

  Future<void> previous() async {
    final action = _queue.previous(_engine.position);
    if (action == PreviousAction.reiniciar) {
      await _engine.seek(Duration.zero);
      return;
    }
    await _loadCurrent();
  }

  Future<void> seek(Duration position) => _engine.seek(position);

  /// Busca por fração da faixa (barra de progresso arrastável).
  Future<void> seekFraction(double fraction) async {
    final duration = _duration;
    if (duration == null) return;
    await seek(duration * fraction.clamp(0.0, 1.0));
  }

  void toggleShuffle() {
    _queue.setShuffle(!_queue.shuffle);
    _publish();
  }

  void cycleRepeat() {
    _queue.repeat = _queue.repeat.next;
    _publish(
      message: PlayerMessage(switch (_queue.repeat) {
        PlayerRepeat.desligado => 'Repetir desligado',
        PlayerRepeat.tudo => 'Repetindo tudo',
        PlayerRepeat.umaFaixa => 'Repetindo esta música',
      }),
    );
  }

  void removeFromQueue(int uid) {
    _queue
      ..removeManual(uid)
      ..removeUpNext(uid);
    _publish();
  }

  void clearQueue() {
    _queue.clearManual();
    _publish();
  }

  void reorderQueue(int oldIndex, int newIndex) {
    _queue.reorderManual(oldIndex, newIndex);
    _publish();
  }

  void reorderUpNext(int oldIndex, int newIndex) {
    _queue.reorderUpNext(oldIndex, newIndex);
    _publish();
  }

  Future<void> _advance({required bool ended}) async {
    final item = _queue.next(ended: ended);
    if (item == null) {
      // Acabou tudo: para no fim (Seção 7.2).
      await _engine.pause();
      await _engine.seek(Duration.zero);
      _publish(status: PlaybackStatus.parado);
      return;
    }
    if (ended && identical(item, state.current)) {
      // Repetir uma faixa.
      _counted = false;
      await _engine.seek(Duration.zero);
      _engine.play();
      return;
    }
    await _loadCurrent();
  }

  void _onCompleted() {
    if (state.status == PlaybackStatus.tocando) {
      unawaited(_advance(ended: true));
    }
  }

  /// Prepara no servidor, espera ficar pronta e toca (Seção 7.3, item 2).
  /// Trocar de faixa no meio cancela a anterior ([_generation]).
  Future<void> _loadCurrent() async {
    final item = _queue.current;
    if (item == null) return;
    final generation = ++_generation;
    _counted = false;
    _duration = null;
    _publish(status: PlaybackStatus.preparando);
    _notification?.showTrack(
      id: item.track.id,
      title: item.track.title,
      artist: item.track.artist,
      album: item.track.album,
      duration: item.track.durationSeconds > 0
          ? Duration(seconds: item.track.durationSeconds)
          : null,
      coverUrl: item.track.coverUrl,
    );
    await _engine.stop();

    // 1. Arquivo baixado no aparelho (funciona sem servidor) — Seção 7.3.
    final local = await ref
        .read(localDatabaseProvider)
        ?.downloadedFor(item.track);
    if (generation != _generation) return;
    final path = local?.audioPath;
    if (path != null && File(path).existsSync()) {
      await _engine.setFile(path);
      if (generation != _generation) return;
      _engine.play();
      _publish(status: PlaybackStatus.tocando);
      return;
    }
    // 3. Sem arquivo e sem servidor: avisa.
    if (!ref.read(sessionProvider).canUseServer) {
      _publish(
        status: PlaybackStatus.erro,
        message: PlayerMessage(notDownloaded),
      );
      return;
    }

    // 2. Streaming do servidor.
    final timings = ref.read(playerTimingsProvider);
    try {
      final prepared = await _repository.prepare(item.track);
      var readiness = prepared.readiness;
      final deadline = DateTime.now().add(timings.prepareTimeout);
      var unknownInARow = 0;
      while (readiness != TrackReadiness.pronta) {
        if (generation != _generation) return;
        if (readiness == TrackReadiness.erro ||
            unknownInARow > 10 ||
            DateTime.now().isAfter(deadline)) {
          throw const ApiException(ApiErrorKind.requisicao);
        }
        await Future<void>.delayed(timings.pollInterval);
        readiness = await _repository.status(prepared.trackId);
        unknownInARow = readiness == TrackReadiness.desconhecido
            ? unknownInARow + 1
            : 0;
      }
      final url = await _repository.streamUrl(prepared.trackId);
      if (generation != _generation) return;
      await _engine.setUrl(url);
      if (generation != _generation) return;
      _engine.play();
      _publish(status: PlaybackStatus.tocando);
    } on Object catch (e) {
      if (generation != _generation) return;
      debugPrint('Falha ao tocar ${item.track.title}: $e');
      _publish(
        status: PlaybackStatus.erro,
        message: PlayerMessage(
          e is ApiException && e.kind == ApiErrorKind.semConexao
              ? e.message
              : notPlayable,
        ),
      );
    }
  }

  void _onDuration(Duration? duration) {
    _duration = duration;
    _publish();
  }

  /// Conta a reprodução no histórico ao passar de 30 s ou da metade.
  void _onPosition(Duration position) {
    final item = state.current;
    if (item == null || _counted || state.status != PlaybackStatus.tocando) {
      return;
    }
    final duration = _duration;
    final half = duration == null ? null : duration * 0.5;
    if (position >= const Duration(seconds: 30) ||
        (half != null && half > Duration.zero && position >= half)) {
      _counted = true;
      ref.read(playRecorderProvider)(item.track);
    }
    _notification?.showState(
      playing: state.isPlaying,
      loading: state.isPreparing,
      position: position,
    );
  }

  void _onNotificationCommand(String command, [Duration? position]) {
    switch (command) {
      case 'play' || 'pause':
        unawaited(togglePlay());
      case 'next':
        unawaited(next());
      case 'previous':
        unawaited(previous());
      case 'stop':
        unawaited(_engine.pause());
        _publish(status: PlaybackStatus.pausado);
      case 'seek':
        if (position != null) unawaited(seek(position));
    }
  }

  void _publish({PlaybackStatus? status, PlayerMessage? message}) {
    state = PlayerState(
      current: _queue.current,
      status: status ?? state.status,
      shuffle: _queue.shuffle,
      repeat: _queue.repeat,
      manual: _queue.manual,
      upNext: _queue.upNext,
      context: _context,
      duration: _duration,
      message: message,
    );
    _notification?.showState(
      playing: state.isPlaying,
      loading: state.isPreparing,
      position: _engine.position,
    );
  }
}
