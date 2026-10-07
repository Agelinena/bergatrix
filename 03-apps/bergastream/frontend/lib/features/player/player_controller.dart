import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_error.dart';
import '../../core/platform/app_platform.dart';
import '../../core/storage/key_value_store.dart';
import '../../data/local/database.dart';
import '../../data/models/search_result.dart';
import '../../data/repositories/playback_repository.dart';
import '../auth/session.dart';
import '../home/home_providers.dart';
import '../playlists/last_played.dart';
import '../playlists/playlist_shuffle.dart';
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
typedef PlayRecorder = void Function(SearchResult track, {String? playlistId});

final playRecorderProvider = Provider<PlayRecorder>((ref) {
  final send = ref.watch(playRecorderServiceProvider);
  return (track, {playlistId}) =>
      unawaited(send(track, playlistId: playlistId));
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
    Future.microtask(_restore);
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
    String? playlistId,
    bool? shuffle,
  }) async {
    // Aleatório da nova lista (sem gravar na playlist que tocava antes).
    if (shuffle != null) _queue.setShuffle(shuffle);
    _queue.playList(tracks, index);
    _context = context;
    _playlistId = playlistId;
    _playlistTracks = playlistId == null
        ? const {}
        : {for (final t in tracks) t.id};
    if (playlistId != null) {
      unawaited(
        ref.read(playlistLastPlayedProvider.notifier).touch(playlistId),
      );
    }
    await _loadCurrent();
  }

  String? _context;

  /// Playlist de onde veio a lista atual (faixas de "Sua fila" não contam).
  String? _playlistId;
  Set<String> _playlistTracks = const {};

  /// Playlist que está tocando (para o botão "Aleatório" da playlist).
  String? get playlistId => _playlistId;

  // ── Continuar de onde parou depois de fechar o app ──

  static const _sessionKey = 'player.session';

  /// Restaurado e ainda não carregado no motor: tocar retoma em [_resumeAt].
  bool _needsLoad = false;
  Duration? _resumeAt;
  DateTime _lastPositionSave = DateTime.fromMillisecondsSinceEpoch(0);
  bool _saving = false;
  bool _saveAgain = false;

  String get _storeKey =>
      '${ref.read(appPlatformProvider).simulated ? 'sim_android.' : ''}$_sessionKey';

  Future<void> _restore() async {
    if (_queue.current != null) return;
    try {
      final raw = await ref.read(keyValueStoreProvider).read(_storeKey);
      if (raw == null || _queue.current != null || !ref.mounted) return;
      final json = jsonDecode(raw) as Map<String, dynamic>;
      _queue.restore(json['queue'] as Map<String, dynamic>);
      if (_queue.current == null) return;
      _context = json['context'] as String?;
      _playlistId = json['playlist_id'] as String?;
      _playlistTracks = _playlistId == null
          ? const {}
          : {
              for (final t in json['playlist_tracks'] as List? ?? const [])
                '$t',
            };
      final ms = json['position_ms'] as int? ?? 0;
      _resumeAt = ms > 0 ? Duration(milliseconds: ms) : null;
      _needsLoad = true;
      _publish(status: PlaybackStatus.pausado);
    } on Object catch (e) {
      debugPrint('Não restaurou o player: $e');
    }
  }

  /// Guarda o que está tocando (fila, posição). Sem timers: uma gravação
  /// por vez; mudanças no meio entram na próxima.
  Future<void> _save({Duration? position}) async {
    if (_saving) {
      _saveAgain = true;
      return;
    }
    _saving = true;
    try {
      do {
        _saveAgain = false;
        final store = ref.read(keyValueStoreProvider);
        if (_queue.current == null) {
          await store.delete(_storeKey);
        } else {
          final at = _needsLoad ? _resumeAt : (position ?? _engine.position);
          await store.write(
            _storeKey,
            jsonEncode({
              'queue': _queue.toJson(),
              'context': _context,
              'playlist_id': _playlistId,
              'playlist_tracks': _playlistTracks.toList(),
              'position_ms': at?.inMilliseconds ?? 0,
            }),
          );
        }
      } while (_saveAgain && ref.mounted);
    } on Object catch (e) {
      debugPrint('Não guardou o player: $e');
    } finally {
      _saving = false;
    }
  }

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
        if (_needsLoad) {
          // Restaurado ao abrir o app: carrega e continua de onde parou.
          await _loadCurrent(startAt: _resumeAt);
          return;
        }
        _engine.play();
        _publish(status: PlaybackStatus.tocando);
        unawaited(_save());
      case PlaybackStatus.parado || PlaybackStatus.erro:
        if (_queue.current != null) await _loadCurrent();
      case PlaybackStatus.preparando:
        break;
    }
  }

  Future<void> next() => _advance(ended: false);

  /// "Anterior". Com [track] (arrastar o mini player), sempre volta para a
  /// música anterior, sem só recomeçar a atual.
  Future<void> previous({bool track = false}) async {
    final action = _queue.previous(track ? Duration.zero : _engine.position);
    if (action == PreviousAction.reiniciar) {
      await _engine.seek(Duration.zero);
      return;
    }
    await _loadCurrent();
  }

  Future<void> seek(Duration position) async {
    if (_needsLoad) {
      _resumeAt = position;
      unawaited(_save());
      return;
    }
    await _engine.seek(position);
  }

  /// Busca por fração da faixa (barra de progresso arrastável).
  Future<void> seekFraction(double fraction) async {
    final duration = _duration;
    if (duration == null) return;
    await seek(duration * fraction.clamp(0.0, 1.0));
  }

  /// Botão "Aleatório" do player. Tocando uma playlist, a escolha fica
  /// guardada nela.
  void toggleShuffle() => setShuffle(!_queue.shuffle);

  void setShuffle(bool value) {
    if (value == _queue.shuffle) return;
    _queue.setShuffle(value);
    final playlist = _playlistId;
    if (playlist != null) {
      unawaited(
        ref.read(playlistShuffleProvider(playlist).notifier).set(value),
      );
    }
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
  Future<void> _loadCurrent({Duration? startAt}) async {
    final item = _queue.current;
    if (item == null) return;
    _needsLoad = false;
    _resumeAt = null;
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
      if (startAt != null) await _engine.seek(startAt);
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
      if (startAt != null) await _engine.seek(startAt);
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
    // Posição guardada a cada 10 s (para continuar ao reabrir o app).
    if (state.isPlaying &&
        DateTime.now().difference(_lastPositionSave) >
            const Duration(seconds: 10)) {
      _lastPositionSave = DateTime.now();
      unawaited(_save(position: position));
    }
    final item = state.current;
    if (item == null || _counted || state.status != PlaybackStatus.tocando) {
      return;
    }
    final duration = _duration;
    final half = duration == null ? null : duration * 0.5;
    if (position >= const Duration(seconds: 30) ||
        (half != null && half > Duration.zero && position >= half)) {
      _counted = true;
      ref.read(playRecorderProvider)(
        item.track,
        playlistId: _playlistTracks.contains(item.track.id)
            ? _playlistId
            : null,
      );
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
    final changed =
        state.current?.uid != _queue.current?.uid ||
        state.upNext.length != _queue.upNext.length ||
        state.manual.length != _queue.manual.length ||
        state.shuffle != _queue.shuffle ||
        state.repeat != _queue.repeat ||
        (status != null && status != state.status);
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
    if (changed) unawaited(_save());
  }
}
