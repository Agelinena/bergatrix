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
import '../../data/repositories/session_repository.dart';
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
    this.shared = false,
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

  /// Tocando numa sessão compartilhada ("ouvir junto"): a fila é a da
  /// sessão e aleatório/repetir ficam desligados.
  final bool shared;

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
    this.rapidChangeDelay = const Duration(milliseconds: 500),
    this.prefetchAfter = const Duration(seconds: 20),
  });

  final Duration pollInterval;
  final Duration prepareTimeout;

  /// Trocas seguidas de música (vários toques rápidos): espera isto antes de
  /// pedir ao servidor, para não baixar as que foram só "passadas".
  final Duration rapidChangeDelay;

  /// Depois de tocar isto (ou metade de uma faixa curta), pede ao servidor
  /// para preparar só a próxima: a troca fica instantânea.
  final Duration prefetchAfter;
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

/// Sessão compartilhada ligada ao player (ver `features/session`). O player
/// manda as ações para ela em vez de mexer na própria fila e pergunta onde
/// a música deveria estar.
abstract interface class SharedPlayback {
  /// Onde a música deveria estar agora.
  Duration get position;

  /// Se este aparelho deve estar tocando (a sessão toca e ninguém pausou
  /// aqui).
  bool get shouldPlay;

  void act(Map<String, Object?> action);

  Future<void> togglePlay();
}

final playerProvider = NotifierProvider<PlayerController, PlayerState>(
  PlayerController.new,
);

class PlayerController extends Notifier<PlayerState> {
  final _queue = PlayQueue();
  int _generation = 0;

  /// Quando começou a carregar a faixa anterior (detecta trocas rápidas).
  DateTime _lastLoadAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Faixa cuja próxima já foi pedida ao servidor.
  int? _prefetchedFor;
  Duration? _duration;
  bool _counted = false;
  final _subscriptions = <StreamSubscription<Object?>>[];

  AudioEngine get _engine => ref.read(audioEngineProvider);
  PlaybackRepository get _repository => ref.read(playbackRepositoryProvider);
  BergaAudioHandler? get _notification => ref.read(mediaNotificationProvider);

  static const notPlayable = 'Não foi possível tocar esta música.';
  static const notDownloaded = 'Esta música não está baixada.';
  static const sharedQueue = 'Na sessão, a ordem da fila é a mesma para todos.';

  /// Diferença tolerada para o ponto da sessão antes de corrigir.
  static const sessionDriftTolerance = Duration(milliseconds: 1500);

  /// Máximo de faixas mandadas de uma vez para a sessão (o servidor corta
  /// em 2000).
  static const sessionMaxTracks = 2000;

  // ── Sessão compartilhada ──

  SharedPlayback? _group;

  /// uid local → uid na sessão.
  final _sharedUids = <int, String>{};
  List<String> _sharedOrder = const [];
  int _sharedIndex = -1;

  /// Faixa que está (ou ficou) carregada no motor.
  String? _loadedTrackId;

  bool get inSession => _group != null;

  /// Entra numa sessão: a partir de agora a fila é a dela.
  void attachGroup(SharedPlayback group) {
    _group = group;
    _sharedOrder = const [];
    _sharedIndex = -1;
    _publish();
  }

  /// Saiu da sessão: a música para e a fila fica como estava.
  void detachGroup() {
    if (_group == null || !ref.mounted) return;
    _group = null;
    _sharedUids.clear();
    _sharedOrder = const [];
    _sharedIndex = -1;
    _generation++;
    unawaited(_engine.pause());
    _publish(
      status: _queue.current == null
          ? PlaybackStatus.parado
          : PlaybackStatus.pausado,
    );
  }

  /// O que está tocando aqui, para começar uma sessão com isso.
  ({List<SearchResult> tracks, Duration position, bool playing})?
  sessionSeed() {
    final current = _queue.current;
    if (current == null) return null;
    return (
      tracks: [
        current.track,
        for (final i in _queue.manual) i.track,
        for (final i in _queue.upNext) i.track,
      ],
      position: _needsLoad ? (_resumeAt ?? Duration.zero) : _engine.position,
      playing: state.isPlaying || state.isPreparing,
    );
  }

  /// Aviso rápido (a sessão usa para "Marina pausou", erros...).
  void showMessage(String text) => _publish(message: PlayerMessage(text));

  /// Segue o estado da sessão: troca a fila, carrega a faixa atual no ponto
  /// certo, pausa/toca e corrige atrasos maiores que
  /// [sessionDriftTolerance].
  Future<void> applySession(
    SessionPlayback playback, {
    required String context,
  }) async {
    final group = _group;
    if (group == null) return;
    _context = context;
    _playlistId = null;
    _playlistTracks = const {};
    final order = [for (final e in playback.queue) e.uid];
    if (playback.index != _sharedIndex || !listEquals(order, _sharedOrder)) {
      _sharedOrder = order;
      _sharedIndex = playback.index;
      final items = _queue.loadShared([
        for (final e in playback.queue) e.track,
      ], playback.index);
      _sharedUids
        ..clear()
        ..addAll({
          for (final (i, item) in items.indexed)
            item.uid: playback.queue[i].uid,
        });
    }
    final current = _queue.current;
    if (current == null) {
      // Sessão sem nada tocando.
      _generation++;
      _loadedTrackId = null;
      await _engine.pause();
      if (!ref.mounted) return;
      _publish(status: PlaybackStatus.parado);
      return;
    }
    final sameTrack = _loadedTrackId == current.track.id;
    if (sameTrack && state.isPreparing) {
      // Carregando: ao terminar, pega o ponto da sessão daquele momento.
      _publish();
      return;
    }
    if (!sameTrack ||
        _needsLoad ||
        state.status == PlaybackStatus.parado ||
        state.status == PlaybackStatus.erro) {
      await _loadCurrent();
      return;
    }
    final shouldPlay = group.shouldPlay;
    // Pausado só aqui (cada um pausa o seu): o ponto não importa até voltar.
    if (shouldPlay || !playback.playing) {
      final expected = group.position;
      if ((_engine.position - expected).abs() > sessionDriftTolerance) {
        await _engine.seek(expected);
        if (!ref.mounted) return;
      }
    }
    if (shouldPlay && !state.isPlaying) {
      _engine.play();
      _publish(status: PlaybackStatus.tocando);
    } else if (!shouldPlay && state.isPlaying) {
      await _engine.pause();
      if (!ref.mounted) return;
      _publish(status: PlaybackStatus.pausado);
    } else {
      _publish();
    }
  }

  String? _sharedUidOf(int localUid) => _sharedUids[localUid];

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
    if (_group case final group?) {
      // Na sessão: a lista vai para todos (aleatório = embaralhada aqui).
      var list = tracks;
      var start = index;
      if (shuffle ?? false) {
        list = [
          tracks[index],
          ...([...tracks]..removeAt(index))..shuffle(),
        ];
        start = 0;
      }
      if (list.length > sessionMaxTracks) {
        final from = start.clamp(0, list.length - sessionMaxTracks);
        list = list.sublist(from, from + sessionMaxTracks);
        start -= from;
      }
      group.act({
        'action': 'play_list',
        'tracks': [for (final t in list) t.toJson()],
        'index': start,
      });
      if (playlistId != null) {
        unawaited(
          ref.read(playlistLastPlayedProvider.notifier).touch(playlistId),
        );
      }
      return;
    }
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
    if (_group case final group?) {
      group.act({'action': 'add', 'track': track.toJson()});
      return;
    }
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
    if (_group case final group?) return group.togglePlay();
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

  Future<void> next() async {
    if (_group case final group?) return group.act({'action': 'next'});
    await _advance(ended: false);
  }

  /// "Anterior". Com [track] (arrastar o mini player), sempre volta para a
  /// música anterior, sem só recomeçar a atual.
  Future<void> previous({bool track = false}) async {
    if (_group case final group?) {
      if (track && _sharedIndex > 0) {
        group.act({'action': 'jump', 'uid': _sharedOrder[_sharedIndex - 1]});
      } else {
        group.act({'action': 'previous'});
      }
      return;
    }
    final action = _queue.previous(track ? Duration.zero : _engine.position);
    if (action == PreviousAction.reiniciar) {
      await _engine.seek(Duration.zero);
      return;
    }
    await _loadCurrent();
  }

  Future<void> seek(Duration position) async {
    if (_group case final group?) {
      group.act({'action': 'seek', 'position_ms': position.inMilliseconds});
      // Já pula aqui; a confirmação da sessão chega em seguida.
      if (!state.isPreparing && !_needsLoad) await _engine.seek(position);
      return;
    }
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
    if (_group != null) {
      if (value) showMessage(sharedQueue);
      return;
    }
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
    if (_group != null) return showMessage(sharedQueue);
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
    if (_group case final group?) {
      final shared = _sharedUidOf(uid);
      if (shared != null) group.act({'action': 'remove', 'uid': shared});
      return;
    }
    _queue
      ..removeManual(uid)
      ..removeUpNext(uid);
    _publish();
  }

  void clearQueue() {
    if (_group != null) return;
    _queue.clearManual();
    _publish();
  }

  void reorderQueue(int oldIndex, int newIndex) {
    if (_group != null) return;
    _queue.reorderManual(oldIndex, newIndex);
    _publish();
  }

  void reorderUpNext(int oldIndex, int newIndex) {
    if (_group case final group?) {
      final upNext = _queue.upNext;
      if (oldIndex < 0 || oldIndex >= upNext.length) return;
      final shared = _sharedUidOf(upNext[oldIndex].uid);
      if (shared == null) return;
      // Mesma conta do servidor: posição final na fila inteira.
      group.act({
        'action': 'move',
        'uid': shared,
        'to': _sharedIndex + 1 + newIndex,
      });
      // Mostra já na nova ordem; a sessão confirma em seguida.
      _queue.reorderUpNext(oldIndex, newIndex);
      _publish();
      return;
    }
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
    if (_group case final group?) {
      // Na sessão quem avança é o servidor (o primeiro aviso vale).
      final uid = state.current == null
          ? null
          : _sharedUidOf(state.current!.uid);
      if (uid != null) group.act({'action': 'ended', 'uid': uid});
      return;
    }
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
    _loadedTrackId = item.track.id;
    _publish(status: PlaybackStatus.preparando);
    _prefetchedFor = null;
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
    // Pausa (e não "stop"): o serviço de mídia continua ativo na troca.
    await _engine.pause();

    // 1. Arquivo baixado no aparelho (funciona sem servidor) — Seção 7.3.
    final local = await ref
        .read(localDatabaseProvider)
        ?.downloadedFor(item.track);
    if (generation != _generation) return;
    final path = local?.audioPath;
    if (path != null && File(path).existsSync()) {
      await _engine.setFile(path);
      if (generation != _generation) return;
      await _start(startAt);
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
    // Toques rápidos em várias músicas: só a última vai para o servidor.
    final now = DateTime.now();
    final rapid = now.difference(_lastLoadAt) < const Duration(seconds: 1);
    _lastLoadAt = now;
    if (rapid && timings.rapidChangeDelay > Duration.zero) {
      await Future<void>.delayed(timings.rapidChangeDelay);
      if (generation != _generation) return;
    }
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
      await _start(startAt);
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

  /// Começa a tocar a faixa já carregada. Na sessão, vai para o ponto em
  /// que ela está agora (o download pode ter levado segundos) e só toca se
  /// a sessão estiver tocando.
  Future<void> _start(Duration? startAt) async {
    final group = _group;
    final at = group?.position ?? startAt;
    if (at != null && at > Duration.zero) await _engine.seek(at);
    if (group == null || group.shouldPlay) {
      _engine.play();
      _publish(status: PlaybackStatus.tocando);
    } else {
      _publish(status: PlaybackStatus.pausado);
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
    _maybePrefetch(item, position);
    _notification?.showState(
      playing: state.isPlaying,
      loading: state.isPreparing,
      position: position,
    );
  }

  /// Pede ao servidor só a próxima música, depois de a atual tocar um pouco
  /// (quem passa músicas rápido não dispara downloads).
  void _maybePrefetch(QueueItem current, Duration position) {
    if (_prefetchedFor == current.uid ||
        state.status != PlaybackStatus.tocando) {
      return;
    }
    final after = ref.read(playerTimingsProvider).prefetchAfter;
    final duration = _duration;
    final half = duration == null ? null : duration * 0.5;
    if (position < after && (half == null || position < half)) return;
    _prefetchedFor = current.uid;
    final next = _queue.peekNext;
    if (next == null || !ref.read(sessionProvider).canUseServer) return;
    unawaited(() async {
      try {
        final local = await ref
            .read(localDatabaseProvider)
            ?.downloadedFor(next.track);
        if (local?.audioPath != null) return; // já está no aparelho
        await _repository.prepare(next.track);
      } on Object catch (e) {
        debugPrint('Não preparou a próxima: $e');
      }
    }());
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
      shared: _group != null,
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
      // Preparando a próxima conta como "tocando" para o Android: o serviço
      // de mídia segue em primeiro plano com a CPU acordada (tela bloqueada).
      // Sem isso a troca de faixa parava com a tela desligada.
      playing: state.isPlaying || state.isPreparing,
      loading: state.isPreparing,
      position: _engine.position,
    );
    if (changed) unawaited(_save());
  }
}
