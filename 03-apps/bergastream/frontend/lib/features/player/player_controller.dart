import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

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
import '../downloads/download_manager.dart';
import '../home/home_providers.dart';
import '../playlists/last_played.dart';
import '../playlists/playlist_shuffle.dart';
import '../settings/preferences.dart';
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
    this.playingOn,
    this.quality,
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

  /// Outro aparelho da pessoa é o que está tocando ("Tocando em …"). Os
  /// controles daqui comandam aquele aparelho.
  final String? playingOn;

  /// Qualidade do que está tocando ("FLAC 16/44.1", "MP3 320"), da cópia
  /// baixada ou do que o servidor entrega no nível escolhido. Nula enquanto
  /// não se sabe (ou em outro aparelho).
  final String? quality;

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
    this.pollInterval = const Duration(seconds: 1),
    this.prepareTimeout = const Duration(minutes: 3),
    this.rapidChangeDelay = const Duration(milliseconds: 500),
    this.prefetchAfter = const Duration(seconds: 8),
    this.prefetchRetry = const Duration(seconds: 20),
    this.autoSkipDelay = const Duration(seconds: 2),
    this.fades = true,
    this.pausedKeepAlive = const Duration(minutes: 30),
  });

  /// Fades (pausa e troca de música); os testes desligam para não esperar.
  final bool fades;

  /// Pausado há mais que isto, o player sai do primeiro plano (nulo: nunca).
  final Duration? pausedKeepAlive;

  final Duration pollInterval;
  final Duration prepareTimeout;

  /// Trocas seguidas de música (vários toques rápidos): espera isto antes de
  /// pedir ao servidor, para não baixar as que foram só "passadas".
  final Duration rapidChangeDelay;

  /// Depois de tocar isto (ou metade de uma faixa curta), pede ao servidor
  /// para preparar só a próxima: a troca fica instantânea.
  final Duration prefetchAfter;

  /// O pedido da próxima falhou: tenta de novo depois disto.
  final Duration prefetchRetry;

  /// Música da fila que não tocou (avanço automático): pula para a seguinte
  /// depois disto, em vez de parar tudo.
  final Duration autoSkipDelay;
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
/// Com outro aparelho tocando, é a posição calculada daquele aparelho.
final playerPositionProvider = StreamProvider<Duration>(
  (ref) => ref.watch(playerProvider.notifier).positionStream,
);

/// Outro aparelho da mesma conta que está tocando ("Tocar em…"). O player
/// daqui mostra o estado dele e manda os comandos para ele.
abstract interface class RemoteControl {
  String get deviceName;

  void command(Map<String, Object?> command);
}

/// O que o aparelho que toca conta aos outros (ver [PlayerController.remoteSnapshot]).
class RemotePlayerState {
  RemotePlayerState({
    this.current,
    this.status = PlaybackStatus.parado,
    this.positionMs = 0,
    this.durationMs,
    this.context,
    this.shuffle = false,
    this.repeat = PlayerRepeat.desligado,
    this.manual = const [],
    this.upNext = const [],
    required this.receivedAt,
  });

  /// [receivedAt]: relógio daqui (ms) do instante em que [positionMs] valia.
  factory RemotePlayerState.fromJson(
    Map<String, dynamic> json, {
    required int receivedAt,
  }) {
    QueueItem? item(Object? raw) {
      if (raw is! Map<String, dynamic>) return null;
      return QueueItem(
        raw['uid'] as int,
        SearchResult.fromJson(raw['track'] as Map<String, dynamic>),
      );
    }

    List<QueueItem> items(Object? raw) => [
      for (final r in raw as List<dynamic>? ?? const []) ?item(r),
    ];
    return RemotePlayerState(
      current: item(json['current']),
      status: PlaybackStatus.values.firstWhere(
        (s) => s.name == json['status'],
        orElse: () => PlaybackStatus.parado,
      ),
      positionMs: json['position_ms'] as int? ?? 0,
      durationMs: json['duration_ms'] as int?,
      context: json['context'] as String?,
      shuffle: json['shuffle'] as bool? ?? false,
      repeat: PlayerRepeat.values.firstWhere(
        (r) => r.name == json['repeat'],
        orElse: () => PlayerRepeat.desligado,
      ),
      manual: items(json['manual']),
      upNext: items(json['up_next']),
      receivedAt: receivedAt,
    );
  }

  final QueueItem? current;
  final PlaybackStatus status;
  final int positionMs;
  final int? durationMs;
  final String? context;
  final bool shuffle;
  final PlayerRepeat repeat;
  final List<QueueItem> manual;
  final List<QueueItem> upNext;
  final int receivedAt;

  Duration? get duration =>
      durationMs == null ? null : Duration(milliseconds: durationMs!);

  /// Posição agora (relógio daqui em ms), sem passar do fim.
  Duration positionAt(int nowMs) {
    var ms = positionMs;
    if (status == PlaybackStatus.tocando) ms += max(0, nowMs - receivedAt);
    if (durationMs != null) ms = min(ms, durationMs!);
    return Duration(milliseconds: ms);
  }
}

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

  /// O sistema pausou este aparelho (fone desconectado, ligação): pausa só
  /// aqui, sem pausar a sessão.
  void pausedHere();
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
  DateTime _prefetchRetryAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Faixa atual vem do servidor (id lá), não de arquivo no aparelho.
  String? _streamTrackId;

  // ── Volume: do usuário × normalização × fade ──

  double _userVolume = 1;

  /// Ganho da normalização da faixa atual (só abaixa: 0..1).
  double _trackGain = 1;
  double _fade = 1;
  int _fadeGen = 0;

  /// Fade de fim de música em andamento (troca com fade).
  bool _fadingOut = false;
  Timer? _idleTimer;

  /// Alvo da normalização (o mesmo do Spotify no modo normal).
  static const loudnessTarget = -14.0;

  void _applyVolume() {
    unawaited(
      _engine.setVolume((_userVolume * _trackGain * _fade).clamp(0.0, 1.0)),
    );
  }

  /// Leva o fade a [target] em [ms] (passos de 25 ms). Um fade novo cancela
  /// o anterior. Devolve se terminou (não foi cancelado).
  Future<bool> _fadeTo(double target, int ms) async {
    final token = ++_fadeGen;
    if (ms <= 0 || !ref.read(playerTimingsProvider).fades) {
      _fade = target;
      _applyVolume();
      return true;
    }
    final start = _fade;
    final steps = (ms / 25).ceil().clamp(1, 400);
    for (var i = 1; i <= steps; i++) {
      await Future<void>.delayed(Duration(milliseconds: ms ~/ steps));
      if (token != _fadeGen || !ref.mounted) return false;
      _fade = start + (target - start) * i / steps;
      _applyVolume();
    }
    return true;
  }

  Preferences get _prefs => ref.read(preferencesProvider);

  /// Volume da barra (computador e web). [save] falso enquanto arrasta.
  void setVolume(double volume, {bool save = true}) {
    _userVolume = volume.clamp(0.0, 1.0);
    _applyVolume();
    unawaited(
      ref.read(preferencesProvider.notifier).setVolume(_userVolume, save: save),
    );
  }

  /// Ganho da normalização para [track]: abaixa até [loudnessTarget] (o
  /// player não aumenta acima de 1). A medida fica guardada no aparelho
  /// (vale offline); sem medida, sem ajuste.
  Future<double> _gainFor(SearchResult track) async {
    if (!_prefs.normalizeVolume) return 1;
    final loud = await _loudnessOf(track);
    if (loud == null) return 1;
    final db = loudnessTarget - loud.lufs;
    return db >= 0 ? 1 : pow(10, db / 20).toDouble();
  }

  Future<TrackLoudness?> _loudnessOf(SearchResult track) async {
    final key = 'loudness.${track.id}';
    final store = ref.read(keyValueStoreProvider);
    try {
      final cached = await store.read(key);
      if (cached != null) {
        return TrackLoudness.fromJson(
          jsonDecode(cached) as Map<String, dynamic>,
        );
      }
      if (!ref.read(sessionProvider).canUseServer) return null;
      final found = (await _repository
          .loudness([track.id])
          .timeout(const Duration(milliseconds: 800)))[track.id];
      if (found != null) await store.write(key, jsonEncode(found.toJson()));
      return found;
    } on Object catch (e) {
      debugPrint('Volume da faixa não informado: $e');
      return null;
    }
  }

  /// Pausado/parado por muito tempo: sai do primeiro plano. Tocando:
  /// cancela.
  void _watchIdle(PlaybackStatus status) {
    final keepAlive = ref.read(playerTimingsProvider).pausedKeepAlive;
    final idle =
        status == PlaybackStatus.pausado || status == PlaybackStatus.parado;
    if (!idle ||
        keepAlive == null ||
        _notification == null ||
        _remote != null) {
      _idleTimer?.cancel();
      _idleTimer = null;
      return;
    }
    _idleTimer ??= Timer(keepAlive, () {
      _idleTimer = null;
      if (ref.mounted && !state.isPlaying) _notification?.idle();
    });
  }

  /// Último ponto visto da faixa (o motor zera a posição ao terminar).
  Duration _lastPosition = Duration.zero;

  /// Retomadas do stream nesta faixa (cortado no meio).
  int _streamResumes = 0;
  static const maxStreamResumes = 2;

  /// A faixa atual entrou por avanço automático (fim da anterior): se não
  /// tocar, pula para a seguinte. Contador evita pular a fila inteira.
  bool _autoAdvanced = false;
  int _autoSkips = 0;
  static const maxAutoSkips = 3;
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

  // ── Outro aparelho tocando ("Tocar em…") ──

  RemoteControl? _remote;
  RemotePlayerState? _remoteState;

  /// Status do player daqui enquanto mostra o outro aparelho.
  PlaybackStatus _localStatus = PlaybackStatus.parado;
  Timer? _remoteTicker;
  String? _playingOn;
  final _positions = StreamController<Duration>.broadcast();

  /// Posição para a barra e a letra (daqui ou do aparelho que toca).
  Stream<Duration> get positionStream => _positions.stream;

  bool get isRemote => _remote != null;

  /// Outro aparelho passou a tocar: este para e vira controle remoto.
  void attachRemote(RemoteControl remote) {
    if (_remote == null) {
      _localStatus = switch (state.status) {
        PlaybackStatus.tocando ||
        PlaybackStatus.preparando => PlaybackStatus.pausado,
        final other => other,
      };
      _generation++;
      unawaited(_own(_engine.pause));
    }
    _remote = remote;
    _remoteTicker ??= Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _emitRemotePosition(),
    );
    _publish();
  }

  /// Volta a mostrar o player daqui (o outro aparelho saiu ou passou a vez).
  void detachRemote() {
    if (_remote == null || !ref.mounted) return;
    _remote = null;
    _remoteState = null;
    _remoteTicker?.cancel();
    _remoteTicker = null;
    _publish(status: _localStatus);
    _positions.add(
      _needsLoad ? (_resumeAt ?? Duration.zero) : _engine.position,
    );
  }

  /// Estado novo do aparelho que toca.
  void applyRemoteState(RemotePlayerState remote) {
    if (_remote == null) return;
    _remoteState = remote;
    _publish();
    _emitRemotePosition();
  }

  /// Nome do outro aparelho que está tocando (também na sessão "ouvir
  /// junto", em que este aparelho segue a sessão sem som).
  void setPlayingOn(String? name) {
    if (_playingOn == name || !ref.mounted) return;
    _playingOn = name;
    _publish();
  }

  void _emitRemotePosition() {
    final remote = _remoteState;
    if (remote == null || _positions.isClosed) return;
    _positions.add(remote.positionAt(DateTime.now().millisecondsSinceEpoch));
  }

  /// Resumo do que toca aqui, para os outros aparelhos mostrarem e
  /// controlarem (uids e posições valem para os comandos de volta).
  Map<String, Object?> remoteSnapshot() {
    Map<String, Object?> item(QueueItem i) => {
      'uid': i.uid,
      'track': i.track.toJson(),
    };
    final current = _queue.current;
    return {
      'current': current == null ? null : item(current),
      'status': state.status.name,
      'position_ms':
          (_needsLoad ? (_resumeAt ?? Duration.zero) : _engine.position)
              .inMilliseconds,
      'duration_ms': _duration?.inMilliseconds,
      'context': _context,
      'shuffle': _queue.shuffle,
      'repeat': _queue.repeat.name,
      'manual': [for (final i in _queue.manual.take(100)) item(i)],
      'up_next': [for (final i in _queue.upNext.take(200)) item(i)],
    };
  }

  /// Passa a vez para outro aparelho: para aqui e devolve a fila inteira e
  /// o ponto da música.
  Map<String, Object?> handoffState() {
    final playing = state.isPlaying || state.isPreparing;
    final snapshot = _snapshot();
    _generation++;
    unawaited(_own(_engine.pause));
    if (_queue.current != null) _publish(status: PlaybackStatus.pausado);
    return {...snapshot, 'playing': playing};
  }

  /// Recebe a vez de outro aparelho: mesma fila, mesmo ponto.
  Future<void> playFromHandoff(Map<String, dynamic> json) async {
    try {
      _restoreFrom(json);
    } on Object catch (e) {
      debugPrint('Transferência inválida: $e');
      return;
    }
    if (_queue.current == null) {
      _publish(status: PlaybackStatus.parado);
      return;
    }
    final ms = json['position_ms'] as int? ?? 0;
    final at = ms > 0 ? Duration(milliseconds: ms) : null;
    if (json['playing'] == false) {
      _resumeAt = at;
      _needsLoad = true;
      _publish(status: PlaybackStatus.pausado);
      unawaited(_save());
      return;
    }
    await _loadCurrent(startAt: at);
  }

  // ── Sessão compartilhada ──

  SharedPlayback? _group;

  /// uid local → uid na sessão.
  final _sharedUids = <int, String>{};
  List<String> _sharedOrder = const [];
  int _sharedIndex = -1;
  int _sharedManual = 0;

  /// Faixa que está (ou ficou) carregada no motor.
  String? _loadedTrackId;

  /// Qualidade do que está tocando (ver PlayerState.quality).
  String? _quality;

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
    unawaited(_own(_engine.pause));
    _publish(
      status: _queue.current == null
          ? PlaybackStatus.parado
          : PlaybackStatus.pausado,
    );
  }

  /// O que está tocando aqui, para começar uma sessão com isso.
  ({
    List<SearchResult> tracks,
    List<SearchResult> manual,
    Duration position,
    bool playing,
  })?
  sessionSeed() {
    final current = _queue.current;
    if (current == null) return null;
    return (
      tracks: [current.track, for (final i in _queue.upNext) i.track],
      manual: [for (final i in _queue.manual) i.track],
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
    final manual = playback.manualCount;
    if (playback.index != _sharedIndex ||
        manual != _sharedManual ||
        !listEquals(order, _sharedOrder)) {
      _sharedOrder = order;
      _sharedIndex = playback.index;
      _sharedManual = manual;
      final items = _queue.loadShared(
        [for (final e in playback.queue) e.track],
        playback.index,
        manual: manual,
      );
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
      await _own(_engine.pause);
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
      await _own(_engine.pause);
      if (!ref.mounted) return;
      _publish(status: PlaybackStatus.pausado);
    } else {
      _publish();
    }
  }

  String? _sharedUidOf(int localUid) => _sharedUids[localUid];

  /// "Mover" na sessão: [list] é a fila manual ([offset] 0) ou "a seguir"
  /// ([offset] = tamanho da fila manual). Mesma conta do servidor: posição
  /// final na fila inteira.
  void _reorderShared(
    List<QueueItem> list,
    int oldIndex,
    int newIndex, {
    required int offset,
  }) {
    if (oldIndex < 0 || oldIndex >= list.length) return;
    final shared = _sharedUidOf(list[oldIndex].uid);
    if (shared == null) return;
    _group?.act({
      'action': 'move',
      'uid': shared,
      'to': _sharedIndex + 1 + offset + newIndex,
    });
  }

  @override
  PlayerState build() {
    final engine = ref.watch(audioEngineProvider);
    // Volume e normalização seguem as preferências (lidas do aparelho).
    ref.listen(preferencesProvider, (before, now) {
      if (before?.volume != now.volume) {
        _userVolume = now.volume;
        _applyVolume();
      }
      if (before?.normalizeVolume != now.normalizeVolume) {
        final track = _queue.current?.track;
        if (!now.normalizeVolume) {
          _trackGain = 1;
          _applyVolume();
        } else if (track != null) {
          unawaited(
            _gainFor(track).then((g) {
              _trackGain = g;
              _applyVolume();
            }),
          );
        }
      }
    });
    _subscriptions
      ..add(engine.completedStream.listen((_) => _onCompleted()))
      ..add(engine.durationStream.listen(_onDuration))
      ..add(engine.positionStream.listen(_onPosition))
      ..add(engine.playingStream.listen(_onEnginePlaying))
      ..add(engine.errorStream.listen(_onEngineError));
    _notification?.onCommand = _onNotificationCommand;
    Future.microtask(_restore);
    ref.onDispose(() {
      for (final s in _subscriptions) {
        s.cancel();
      }
      _remoteTicker?.cancel();
      _idleTimer?.cancel();
      _positions.close();
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
    if (_remote case final remote?) {
      remote.command({
        'action': 'play_list',
        'tracks': [for (final t in tracks.take(sessionMaxTracks)) t.toJson()],
        'index': index.clamp(0, sessionMaxTracks - 1),
        'context': context,
        'playlist_id': playlistId,
        'shuffle': shuffle,
      });
      return;
    }
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
      _restoreFrom(json);
      if (_queue.current == null) return;
      final ms = json['position_ms'] as int? ?? 0;
      _resumeAt = ms > 0 ? Duration(milliseconds: ms) : null;
      _needsLoad = true;
      _publish(status: PlaybackStatus.pausado);
    } on Object catch (e) {
      debugPrint('Não restaurou o player: $e');
    }
  }

  /// Fila, origem e posição (o que se guarda e o que vai para outro
  /// aparelho).
  Map<String, Object?> _snapshot({Duration? position}) {
    final at = _needsLoad ? _resumeAt : (position ?? _engine.position);
    return {
      'queue': _queue.toJson(),
      'context': _context,
      'playlist_id': _playlistId,
      'playlist_tracks': _playlistTracks.toList(),
      'position_ms': at?.inMilliseconds ?? 0,
    };
  }

  void _restoreFrom(Map<String, dynamic> json) {
    _queue.restore(json['queue'] as Map<String, dynamic>);
    _context = json['context'] as String?;
    _playlistId = json['playlist_id'] as String?;
    _playlistTracks = _playlistId == null
        ? const {}
        : {for (final t in json['playlist_tracks'] as List? ?? const []) '$t'};
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
          await store.write(
            _storeKey,
            jsonEncode(_snapshot(position: position)),
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
    if (_remote case final remote?) {
      remote.command({'action': 'add', 'track': track.toJson()});
      return;
    }
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
    if (_remote case final remote?) {
      remote.command({'action': 'toggle'});
      return;
    }
    if (_group case final group?) return group.togglePlay();
    switch (state.status) {
      case PlaybackStatus.tocando:
        // Mostra pausado já; o som desce em pauseFadeMs e aí o motor para.
        _publish(status: PlaybackStatus.pausado);
        final faded = await _fadeTo(0, _prefs.pauseFadeMs);
        if (faded && state.status == PlaybackStatus.pausado) {
          await _own(_engine.pause);
        }
      case PlaybackStatus.pausado:
        if (_needsLoad) {
          // Restaurado ao abrir o app: carrega e continua de onde parou.
          await _loadCurrent(startAt: _resumeAt);
          return;
        }
        final fadeMs = _prefs.pauseFadeMs;
        if (fadeMs > 0 && ref.read(playerTimingsProvider).fades) {
          _fade = 0;
          _applyVolume();
        }
        _engine.play();
        _publish(status: PlaybackStatus.tocando);
        unawaited(_save());
        unawaited(_fadeTo(1, fadeMs));
      case PlaybackStatus.parado || PlaybackStatus.erro:
        if (_queue.current != null) await _loadCurrent();
      case PlaybackStatus.preparando:
        break;
    }
  }

  /// "Adicionar à fila" de uma lista inteira (playlist, álbum), na ordem.
  Future<void> addAllToQueue(List<SearchResult> tracks) async {
    if (tracks.isEmpty) return;
    if (_remote case final remote?) {
      for (final t in tracks) {
        remote.command({'action': 'add', 'track': t.toJson()});
      }
      return;
    }
    if (_group case final group?) {
      for (final t in tracks) {
        group.act({'action': 'add', 'track': t.toJson()});
      }
      return;
    }
    for (final t in tracks) {
      _queue.add(t);
    }
    if (state.current == null) {
      _queue.startFromManual();
      _context = 'Sua fila';
      await _loadCurrent();
    } else {
      _publish();
    }
  }

  /// Toque numa música da fila: pula direto para ela.
  Future<void> jumpTo(int uid) async {
    if (_remote case final remote?) {
      remote.command({'action': 'jump', 'uid': uid});
      return;
    }
    if (_group case final group?) {
      final shared = _sharedUidOf(uid);
      if (shared != null) group.act({'action': 'jump', 'uid': shared});
      return;
    }
    if (_queue.jumpTo(uid) == null) return;
    await _loadCurrent();
  }

  /// "Baixar de novo" da música que está tocando: carrega outra vez (espera
  /// o servidor baixar).
  Future<void> reloadCurrent() async {
    if (_remote != null || _group != null || _queue.current == null) return;
    await _loadCurrent();
  }

  Future<void> next() async {
    if (_remote case final remote?) {
      remote.command({'action': 'next'});
      return;
    }
    if (_group case final group?) return group.act({'action': 'next'});
    await _advance(ended: false);
  }

  /// "Anterior". Com [track] (arrastar o mini player), sempre volta para a
  /// música anterior, sem só recomeçar a atual.
  Future<void> previous({bool track = false}) async {
    if (_remote case final remote?) {
      remote.command({'action': 'previous', 'track': track});
      return;
    }
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
    if (_remote case final remote?) {
      remote.command({
        'action': 'seek',
        'position_ms': position.inMilliseconds,
      });
      final r = _remoteState;
      if (r != null) {
        // Mostra já no ponto novo; o aparelho que toca confirma em seguida.
        _remoteState = RemotePlayerState(
          current: r.current,
          status: r.status,
          positionMs: position.inMilliseconds,
          durationMs: r.durationMs,
          context: r.context,
          shuffle: r.shuffle,
          repeat: r.repeat,
          manual: r.manual,
          upNext: r.upNext,
          receivedAt: DateTime.now().millisecondsSinceEpoch,
        );
        _emitRemotePosition();
      }
      return;
    }
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
  void toggleShuffle() =>
      setShuffle(!(_remote != null ? state.shuffle : _queue.shuffle));

  void setShuffle(bool value) {
    if (_remote case final remote?) {
      remote.command({'action': 'shuffle', 'value': value});
      return;
    }
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
    if (_remote case final remote?) {
      remote.command({'action': 'repeat'});
      return;
    }
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
    if (_remote case final remote?) {
      remote.command({'action': 'remove', 'uid': uid});
      return;
    }
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
    if (_remote case final remote?) {
      remote.command({'action': 'clear'});
      return;
    }
    if (_group case final group?) {
      group.act({'action': 'clear_manual'});
      return;
    }
    _queue.clearManual();
    _publish();
  }

  void reorderQueue(int oldIndex, int newIndex) {
    if (_remote case final remote?) {
      remote.command({
        'action': 'reorder_manual',
        'from': oldIndex,
        'to': newIndex,
      });
      return;
    }
    if (_group != null) {
      _reorderShared(_queue.manual, oldIndex, newIndex, offset: 0);
      _queue.reorderManual(oldIndex, newIndex);
      _publish();
      return;
    }
    _queue.reorderManual(oldIndex, newIndex);
    _publish();
  }

  void reorderUpNext(int oldIndex, int newIndex) {
    if (_remote case final remote?) {
      remote.command({
        'action': 'reorder_next',
        'from': oldIndex,
        'to': newIndex,
      });
      return;
    }
    if (_group != null) {
      _reorderShared(
        _queue.upNext,
        oldIndex,
        newIndex,
        offset: _queue.manual.length,
      );
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
      await _own(_engine.pause);
      await _engine.seek(Duration.zero);
      _publish(status: PlaybackStatus.parado);
      return;
    }
    if (ended && identical(item, state.current)) {
      // Repetir uma faixa.
      _counted = false;
      _lastPosition = Duration.zero;
      _fadingOut = false;
      await _engine.seek(Duration.zero);
      unawaited(_fadeTo(1, _prefs.trackFadeMs));
      _engine.play();
      return;
    }
    await _loadCurrent(auto: ended);
  }

  void _onCompleted() {
    if (_remote != null) return;
    if (_group case final group?) {
      // Na sessão quem avança é o servidor (o primeiro aviso vale).
      final uid = state.current == null
          ? null
          : _sharedUidOf(state.current!.uid);
      if (uid != null) group.act({'action': 'ended', 'uid': uid});
      return;
    }
    if (state.status == PlaybackStatus.tocando) {
      if (_streamCutShort()) {
        unawaited(_resumeStream('terminou cedo'));
        return;
      }
      unawaited(_advance(ended: true));
    }
  }

  /// Duração esperada da faixa atual (a do arquivo ou a dos dados).
  Duration? get _expectedDuration {
    final known = _duration;
    if (known != null && known > Duration.zero) return known;
    final seconds = state.current?.track.durationSeconds ?? 0;
    return seconds > 0 ? Duration(seconds: seconds) : null;
  }

  /// O stream "acabou" longe do fim: foi cortado (rede, arquivo trocado no
  /// servidor), não é o fim da música.
  bool _streamCutShort() {
    final expected = _expectedDuration;
    return _streamTrackId != null &&
        expected != null &&
        _lastPosition < expected - const Duration(seconds: 5) &&
        _streamResumes < maxStreamResumes;
  }

  /// Retoma o stream do ponto em que parou, com uma URL nova.
  Future<void> _resumeStream(String why) async {
    final trackId = _streamTrackId;
    final at = _lastPosition;
    if (trackId == null) return;
    _streamResumes++;
    final generation = _generation;
    debugPrint('Stream $why em ${at.inSeconds}s: retomando ($_streamResumes)');
    try {
      final level = await _streamQuality();
      final url = await _repository.streamUrl(trackId, quality: level.api);
      if (generation != _generation) return;
      await _own(() => _engine.setUrl(url));
      if (generation != _generation) return;
      if (at > Duration.zero) await _engine.seek(at);
      if (generation != _generation) return;
      if (state.isPlaying) _engine.play();
    } on Object catch (e) {
      if (generation != _generation) return;
      debugPrint('Não retomou o stream: $e');
      unawaited(_advance(ended: true));
    }
  }

  /// Operações do próprio app no motor (pausar, trocar a fonte) em curso:
  /// a mudança de "tocando" que elas causam não é do sistema.
  int _ownEngineOps = 0;

  Future<T> _own<T>(Future<T> Function() op) async {
    _ownEngineOps++;
    try {
      return await op();
    } finally {
      _ownEngineOps--;
    }
  }

  /// O motor parou ou voltou a tocar sem o app pedir (Bluetooth/fone
  /// desconectado, ligação, outro app): a tela e a notificação acompanham.
  void _onEnginePlaying(bool playing) {
    if (_remote != null || _ownEngineOps > 0) return;
    if (!playing && state.status == PlaybackStatus.tocando) {
      _group?.pausedHere();
      _publish(status: PlaybackStatus.pausado);
      unawaited(_save());
    } else if (playing &&
        state.status == PlaybackStatus.pausado &&
        !_needsLoad) {
      _publish(status: PlaybackStatus.tocando);
    }
  }

  /// Erro no meio da faixa: retoma o stream; sem como, avisa.
  void _onEngineError(Object error) {
    if (_remote != null || state.status != PlaybackStatus.tocando) return;
    debugPrint('Erro no motor de áudio: $error');
    if (_streamTrackId != null && _streamResumes < maxStreamResumes) {
      unawaited(_resumeStream('com erro'));
      return;
    }
    _publish(status: PlaybackStatus.erro, message: PlayerMessage(notPlayable));
  }

  /// Nível pedido ao servidor para tocar: o do Wi-Fi (ou cabo, ou web) ou o
  /// de dados móveis (Ajustes → Qualidade).
  Future<AudioQuality> _streamQuality() async {
    final notifier = ref.read(preferencesProvider.notifier);
    await notifier.ready;
    final prefs = ref.read(preferencesProvider);
    if (kIsWeb) return prefs.wifiQuality;
    final wifi = await ref.read(networkCheckProvider).onWifi();
    return wifi ? prefs.wifiQuality : prefs.mobileQuality;
  }

  /// O que o servidor entrega no nível (para mostrar no player).
  Future<void> _loadQualityLabel(
    String trackRef,
    String level,
    int generation,
  ) async {
    try {
      final label = (await _repository.qualities([
        trackRef,
      ]))[trackRef]?[level]?.label;
      if (generation != _generation || label == null || label.isEmpty) return;
      _quality = label;
      _publish();
    } on Object catch (e) {
      debugPrint('Qualidade não informada: $e');
    }
  }

  /// Prepara no servidor, espera ficar pronta e toca (Seção 7.3, item 2).
  /// Trocar de faixa no meio cancela a anterior ([_generation]).
  Future<void> _loadCurrent({Duration? startAt, bool auto = false}) async {
    final item = _queue.current;
    if (item == null) return;
    _needsLoad = false;
    _resumeAt = null;
    final generation = ++_generation;
    _counted = false;
    _duration = null;
    _streamTrackId = null;
    _streamResumes = 0;
    _lastPosition = startAt ?? Duration.zero;
    _autoAdvanced = auto;
    if (!auto) _autoSkips = 0;
    _fadingOut = false;
    _quality = null;
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
    await _own(_engine.pause);

    // 1. Arquivo baixado no aparelho (funciona sem servidor) — Seção 7.3.
    final local = await ref
        .read(localDatabaseProvider)
        ?.downloadedFor(item.track);
    if (generation != _generation) return;
    final path = local?.audioPath;
    if (path != null && File(path).existsSync()) {
      _quality = local?.qualityLabel;
      await _own(() => _engine.setFile(path));
      if (generation != _generation) return;
      _trackGain = await _gainFor(item.track);
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
      final level = await _streamQuality();
      final url = await _repository.streamUrl(
        prepared.trackId,
        quality: level.api,
      );
      if (generation != _generation) return;
      unawaited(_loadQualityLabel(item.track.id, level.api, generation));
      await _own(() => _engine.setUrl(url));
      if (generation != _generation) return;
      _streamTrackId = prepared.trackId;
      _trackGain = await _gainFor(item.track);
      if (generation != _generation) return;
      await _start(startAt);
      _autoSkips = 0;
    } on Object catch (e) {
      if (generation != _generation) return;
      debugPrint('Falha ao tocar ${item.track.title}: $e');
      final offline = e is ApiException && e.kind == ApiErrorKind.semConexao;
      _publish(
        status: PlaybackStatus.erro,
        message: PlayerMessage(offline ? e.message : notPlayable),
      );
      // Fila tocando sozinha: pula a que não deu, sem parar tudo.
      if (_autoAdvanced &&
          !offline &&
          _autoSkips < maxAutoSkips &&
          _queue.peekNext != null) {
        _autoSkips++;
        await Future<void>.delayed(
          ref.read(playerTimingsProvider).autoSkipDelay,
        );
        if (generation == _generation && ref.mounted) {
          unawaited(_advance(ended: true));
        }
      }
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
      // Troca com fade: começa do silêncio e sobe em trackFadeMs.
      final fadeMs = _prefs.trackFadeMs;
      final fadeIn = fadeMs > 0 && ref.read(playerTimingsProvider).fades;
      _fadeGen++;
      _fade = fadeIn ? 0 : 1;
      _applyVolume();
      _engine.play();
      _publish(status: PlaybackStatus.tocando);
      if (fadeIn) unawaited(_fadeTo(1, fadeMs));
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
    if (_remote != null) return;
    _positions.add(position);
    // O motor zera a posição ao terminar: guarda o último ponto real.
    if (position > Duration.zero) _lastPosition = position;
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
    _maybeFadeOut(position);
    _maybePrefetch(item, position);
    _notification?.showState(
      playing: state.isPlaying,
      loading: state.isPreparing,
      position: position,
    );
  }

  /// Troca com fade: nos últimos trackFadeMs da música o som desce. Voltou
  /// para trás (buscou um trecho antes), o som volta.
  void _maybeFadeOut(Duration position) {
    final fadeMs = _prefs.trackFadeMs;
    final duration = _duration;
    if (fadeMs <= 0 ||
        duration == null ||
        _group != null ||
        !ref.read(playerTimingsProvider).fades) {
      return;
    }
    final remaining = (duration - position).inMilliseconds;
    if (!_fadingOut &&
        remaining > 0 &&
        remaining <= fadeMs &&
        _queue.peekNext != null) {
      _fadingOut = true;
      unawaited(_fadeTo(0, remaining));
    } else if (_fadingOut && remaining > fadeMs + 500) {
      _fadingOut = false;
      unawaited(_fadeTo(1, 200));
    }
  }

  /// Pede ao servidor só a próxima música, depois de a atual tocar um pouco
  /// (quem passa músicas rápido não dispara downloads).
  void _maybePrefetch(QueueItem current, Duration position) {
    if (_prefetchedFor == current.uid ||
        state.status != PlaybackStatus.tocando ||
        DateTime.now().isBefore(_prefetchRetryAt)) {
      return;
    }
    final timings = ref.read(playerTimingsProvider);
    final duration = _duration;
    final half = duration == null ? null : duration * 0.5;
    if (position < timings.prefetchAfter && (half == null || position < half)) {
      return;
    }
    final next = _queue.peekNext;
    if (next == null || !ref.read(sessionProvider).canUseServer) return;
    // Marca já (não pede duas vezes enquanto espera); se falhar, desmarca e
    // tenta de novo depois de prefetchRetry.
    _prefetchedFor = current.uid;
    unawaited(() async {
      try {
        final local = await ref
            .read(localDatabaseProvider)
            ?.downloadedFor(next.track);
        unawaited(_loudnessOf(next.track)); // volume da próxima, já em cache
        if (local?.audioPath != null) return; // já está no aparelho
        await _repository.prepare(next.track);
      } on Object catch (e) {
        debugPrint('Não preparou a próxima: $e');
        if (_prefetchedFor == current.uid) _prefetchedFor = null;
        _prefetchRetryAt = DateTime.now().add(timings.prefetchRetry);
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
        unawaited(_own(_engine.pause));
        _publish(status: PlaybackStatus.pausado);
      case 'seek':
        if (position != null) unawaited(seek(position));
    }
  }

  void _publish({PlaybackStatus? status, PlayerMessage? message}) {
    if (_remote case final remote?) {
      // Mostra o aparelho que toca; o status daqui fica guardado.
      if (status != null) _localStatus = status;
      final r = _remoteState;
      state = PlayerState(
        current: r?.current,
        status: r?.status ?? PlaybackStatus.parado,
        shuffle: r?.shuffle ?? false,
        repeat: r?.repeat ?? PlayerRepeat.desligado,
        manual: r?.manual ?? const [],
        upNext: r?.upNext ?? const [],
        context: r?.context,
        duration: r?.duration,
        message: message,
        playingOn: remote.deviceName,
      );
      return;
    }
    _watchIdle(status ?? state.status);
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
      playingOn: _playingOn,
      quality: _quality,
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
