import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_error.dart';
import '../../data/repositories/session_repository.dart';
import '../auth/session.dart';
import '../player/player_controller.dart';

/// Sessão compartilhada ("ouvir junto") do lado do app.
///
/// O servidor guarda a fila e o ponto da música; este controlador mantém a
/// conexão em tempo real, acerta o relógio com o do servidor e faz o player
/// seguir a sessão ([SharedPlayback]). As ações do player (próxima, pausar,
/// adicionar à fila...) viram ações da sessão e voltam para todos.

/// Tempos da sessão (os testes desligam os timers).
class GroupTimings {
  const GroupTimings({
    this.invitePoll = const Duration(seconds: 20),
    this.syncCheck = const Duration(seconds: 5),
    this.keepAlive = const Duration(seconds: 25),
    this.reconnectDelays = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 5),
      Duration(seconds: 10),
    ],
  });

  /// Consulta convites e a sessão atual (nulo: não consulta sozinho).
  final Duration? invitePoll;

  /// Confere se a música está no ponto da sessão (atrasos, pausas).
  final Duration? syncCheck;

  /// "ping" para a conexão não cair por inatividade (proxies) e para
  /// refinar o relógio.
  final Duration? keepAlive;

  /// Esperas entre tentativas de reconectar (a última se repete).
  final List<Duration> reconnectDelays;
}

final groupTimingsProvider = Provider<GroupTimings>(
  (ref) => const GroupTimings(),
);

/// Relógio do aparelho em ms (os testes controlam).
final groupClockProvider = Provider<int Function()>(
  (ref) =>
      () => DateTime.now().millisecondsSinceEpoch,
);

class GroupState {
  const GroupState({
    this.info,
    this.connected = false,
    this.invites = const [],
    this.localPaused = false,
  });

  /// Sessão em que a pessoa está (nula: fora de sessão).
  final SessionInfo? info;

  /// Conexão em tempo real ativa.
  final bool connected;

  /// Convites pendentes.
  final List<SessionInvite> invites;

  /// Pausado só neste aparelho ("cada um pausa o seu", ou ao reabrir o app
  /// numa sessão que já estava tocando).
  final bool localPaused;

  bool get active => info != null;

  SessionPlayback get playback => info?.playback ?? const SessionPlayback();

  GroupState copyWith({
    SessionInfo? info,
    bool? connected,
    List<SessionInvite>? invites,
    bool? localPaused,
  }) => GroupState(
    info: info ?? this.info,
    connected: connected ?? this.connected,
    invites: invites ?? this.invites,
    localPaused: localPaused ?? this.localPaused,
  );
}

final groupSessionProvider =
    NotifierProvider<GroupSessionController, GroupState>(
      GroupSessionController.new,
    );

class GroupSessionController extends Notifier<GroupState>
    implements SharedPlayback {
  SessionSocket? _socket;
  StreamSubscription<Map<String, dynamic>>? _messages;
  Timer? _poll;
  Timer? _sync;
  Timer? _keepAlive;
  Timer? _reconnect;
  int _attempt = 0;

  /// Player que está seguindo a sessão (para soltar ao descartar).
  PlayerController? _attached;

  /// Relógio do servidor − relógio daqui (ms), medido pelo ping de menor
  /// ida e volta.
  int _offsetMs = 0;
  int _bestRtt = 1 << 30;

  static const ended = 'A sessão foi encerrada.';
  static const removed = 'Você foi removido da sessão.';
  static const notMember = 'Você não está mais nesta sessão.';
  static const offline = 'Sem conexão com a sessão. Tente de novo.';

  SessionRepository get _repository => ref.read(sessionRepositoryProvider);
  PlayerController get _player => ref.read(playerProvider.notifier);
  GroupTimings get _timings => ref.read(groupTimingsProvider);
  int _now() => ref.read(groupClockProvider)();

  @override
  GroupState build() {
    final loggedIn = ref.watch(sessionProvider.select((s) => s.isLoggedIn));
    ref.onDispose(_teardown);
    if (loggedIn) {
      final every = ref.read(groupTimingsProvider).invitePoll;
      if (every != null) {
        _poll = Timer.periodic(every, (_) => unawaited(refresh()));
      }
      Future.microtask(refresh);
    }
    return const GroupState();
  }

  /// Relógio do servidor agora (ms).
  int get serverNow => _now() + _offsetMs;

  // ── SharedPlayback (usado pelo player) ──

  @override
  Duration get position => state.playback.positionAt(serverNow);

  @override
  bool get shouldPlay =>
      state.playback.playing &&
      state.playback.current != null &&
      !state.localPaused;

  @override
  void act(Map<String, Object?> action) {
    final info = state.info;
    if (info == null) return;
    final socket = _socket;
    if (state.connected && socket != null) {
      socket.send({'type': 'action', ...action});
      return;
    }
    // Sem a conexão em tempo real: manda por HTTP.
    unawaited(() async {
      try {
        final playback = await _repository.act(info.id, action);
        _onPlayback(playback);
      } on ApiException catch (e) {
        _player.showMessage(e.isTransient ? offline : e.message);
      }
    }());
  }

  /// Play/pause. "Pausar para todos": vira ação da sessão. "Cada um pausa
  /// o seu": pausa só aqui; ao voltar, entra no ponto em que os outros
  /// estão.
  @override
  Future<void> togglePlay() async {
    final info = state.info;
    if (info == null) return;
    final pb = state.playback;
    if (shouldPlay) {
      if (info.pauseMode == PauseMode.all) {
        act({'action': 'pause'});
      } else {
        state = state.copyWith(localPaused: true);
        await _apply();
      }
      return;
    }
    state = state.copyWith(localPaused: false);
    if (!pb.playing) act({'action': 'resume'});
    await _apply();
  }

  // ── Entrar, sair, convidar ──

  /// Consulta a sessão atual e os convites. Ao abrir o app numa sessão,
  /// reconecta sem tocar sozinho (fica pausado só aqui até apertar play).
  Future<void> refresh() async {
    if (!ref.read(sessionProvider).canUseServer) return;
    try {
      final mine = await _repository.mine();
      if (!ref.mounted) return;
      state = state.copyWith(invites: mine.invites);
      final current = mine.current;
      if (current != null && state.info == null) {
        _enter(current, localPaused: true);
      } else if (current == null && state.info != null && !state.connected) {
        _exit(ended);
      }
    } on ApiException catch (e) {
      debugPrint('Sessões: ${e.message}');
    }
  }

  /// Cria uma sessão já com o que está tocando aqui.
  Future<void> create({required String name, required PauseMode mode}) async {
    final seed = _player.sessionSeed();
    var info = await _repository.create(name: name, mode: mode);
    if (seed != null) {
      try {
        var playback = await _repository.act(info.id, {
          'action': 'play_list',
          'tracks': [
            for (final t in seed.tracks.take(PlayerController.sessionMaxTracks))
              t.toJson(),
          ],
          'index': 0,
        });
        if (seed.position > Duration.zero) {
          playback = await _repository.act(info.id, {
            'action': 'seek',
            'position_ms': seed.position.inMilliseconds,
          });
        }
        if (!seed.playing && mode == PauseMode.all) {
          playback = await _repository.act(info.id, {'action': 'pause'});
        }
        info = info.copyWith(playback: playback);
      } on ApiException catch (e) {
        debugPrint('Sessão sem a fila atual: ${e.message}');
      }
    }
    _enter(info, localPaused: seed != null && !seed.playing);
  }

  Future<void> join(String sessionId) async {
    final info = await _repository.join(sessionId);
    _enter(info);
  }

  Future<void> decline(String sessionId) async {
    state = state.copyWith(
      invites: [
        for (final i in state.invites)
          if (i.sessionId != sessionId) i,
      ],
    );
    await _repository.decline(sessionId);
  }

  Future<void> invite(List<String> userIds) async {
    final info = state.info;
    if (info == null || userIds.isEmpty) return;
    await _repository.invite(info.id, userIds);
  }

  Future<void> setPauseMode(PauseMode mode) async {
    final info = state.info;
    if (info == null || info.pauseMode == mode) return;
    final updated = await _repository.update(info.id, mode: mode);
    if (state.info?.id != updated.id) return;
    state = state.copyWith(
      info: updated.copyWith(playback: state.playback),
      // Pausa só aqui não existe em "pausar para todos".
      localPaused: mode == PauseMode.all ? false : null,
    );
  }

  Future<void> kick(String userId) async {
    final info = state.info;
    if (info == null) return;
    await _repository.kick(info.id, userId);
  }

  /// Sai da sessão (a música para aqui; os outros seguem).
  Future<void> leave() async {
    final info = state.info;
    if (info == null) return;
    _exit(null);
    await _repository.leave(info.id);
  }

  /// Encerra para todos (só quem criou).
  Future<void> end() async {
    final info = state.info;
    if (info == null) return;
    _exit(null);
    await _repository.end(info.id);
  }

  void _enter(SessionInfo info, {bool localPaused = false}) {
    _closeConnection();
    _offsetMs = info.serverNow > 0 ? info.serverNow - _now() : 0;
    _bestRtt = 1 << 30;
    state = GroupState(
      info: info,
      localPaused: localPaused,
      invites: [
        for (final i in state.invites)
          if (i.sessionId != info.id) i,
      ],
    );
    _attached = _player..attachGroup(this);
    unawaited(_apply());
    _connect();
    final every = _timings.syncCheck;
    if (every != null) {
      _sync = Timer.periodic(every, (_) => unawaited(_apply()));
    }
  }

  void _exit(String? message) {
    _closeConnection();
    _sync?.cancel();
    _sync = null;
    state = GroupState(invites: state.invites);
    _attached = null;
    _player.detachGroup();
    if (message != null) _player.showMessage(message);
  }

  // ── Conexão em tempo real ──

  void _connect() {
    final info = state.info;
    final server = ref.read(sessionProvider).server;
    final token = ref.read(sessionProvider.notifier).accessToken;
    if (info == null || server == null) return;
    final socket = ref.read(sessionSocketFactoryProvider)(
      server: server,
      sessionId: info.id,
    );
    _socket = socket;
    socket.send({'type': 'auth', 'token': token ?? ''});
    _messages = socket.messages.listen(
      _onMessage,
      onDone: () => _onClosed(socket),
      onError: (Object e) => debugPrint('Sessão: conexão com erro: $e'),
      cancelOnError: false,
    );
  }

  void _closeConnection() {
    _reconnect?.cancel();
    _reconnect = null;
    _keepAlive?.cancel();
    _keepAlive = null;
    unawaited(_messages?.cancel());
    _messages = null;
    unawaited(_socket?.close());
    _socket = null;
  }

  void _ping() => _socket?.send({'type': 'ping', 't0': _now()});

  void _onMessage(Map<String, dynamic> message) {
    switch (message['type']) {
      case 'hello':
        final info = SessionInfo.fromJson(
          message['session'] as Map<String, dynamic>,
        );
        if (_bestRtt == 1 << 30 && info.serverNow > 0) {
          _offsetMs = info.serverNow - _now();
        }
        _attempt = 0;
        state = state.copyWith(info: info, connected: true);
        // Algumas medidas de relógio; vale a de menor ida e volta.
        for (var i = 0; i < 3; i++) {
          _ping();
        }
        final every = _timings.keepAlive;
        _keepAlive?.cancel();
        if (every != null) _keepAlive = Timer.periodic(every, (_) => _ping());
        unawaited(_apply());
      case 'pong':
        final t0 = message['t0'];
        final serverTime = message['server_now'];
        if (t0 is int && serverTime is int) {
          final rtt = _now() - t0;
          if (rtt >= 0 && rtt <= _bestRtt) {
            _bestRtt = rtt;
            _offsetMs = serverTime - (t0 + rtt ~/ 2);
          }
        }
      case 'session':
        final info = SessionInfo.fromJson(
          message['session'] as Map<String, dynamic>,
        );
        final previous = state.playback;
        // A reprodução mais nova vence (as mensagens podem se cruzar).
        state = state.copyWith(
          info: info.playback.version >= previous.version
              ? info
              : info.copyWith(playback: previous),
          localPaused: info.pauseMode == PauseMode.all ? false : null,
        );
        unawaited(_apply());
      case 'playback':
        _onPlayback(
          SessionPlayback.fromJson(message['playback'] as Map<String, dynamic>),
          by: message['by'] as String?,
          serverTime: message['server_now'] as int?,
        );
      case 'ended':
        _exit(ended);
      case 'removed':
        _exit(removed);
      case 'left':
        _exit(null);
      case 'error':
        _player.showMessage(
          message['message'] as String? ?? 'Ação não permitida.',
        );
    }
  }

  void _onPlayback(SessionPlayback playback, {String? by, int? serverTime}) {
    final info = state.info;
    if (info == null) return;
    final previous = info.playback;
    if (playback.version < previous.version) return;
    state = state.copyWith(info: info.copyWith(playback: playback));
    // Avisa quando outra pessoa pausou ou voltou a tocar para todos.
    final me = ref.read(sessionProvider).username;
    if (by != null &&
        by != me &&
        playback.playing != previous.playing &&
        playback.current?.uid == previous.current?.uid &&
        playback.current != null) {
      _player.showMessage(
        '${info.nameOf(by)} ${playback.playing ? 'voltou a tocar' : 'pausou'}',
      );
    }
    unawaited(_apply());
  }

  void _onClosed(SessionSocket socket) {
    if (!identical(socket, _socket)) return; // conexão antiga
    _socket = null;
    _keepAlive?.cancel();
    unawaited(_messages?.cancel());
    _messages = null;
    if (state.info == null) return;
    state = state.copyWith(connected: false);
    switch (socket.closeCode) {
      case 4403:
        _exit(notMember);
      case 4401:
        // Login vencido: renova e tenta de novo.
        unawaited(
          ref.read(sessionProvider.notifier).refreshTokens().then((ok) {
            if (ok && state.info != null && _socket == null) {
              _connect();
            } else {
              _scheduleReconnect();
            }
          }),
        );
      default:
        _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (state.info == null || _reconnect != null) return;
    final delays = _timings.reconnectDelays;
    if (delays.isEmpty) return;
    final delay = delays[_attempt.clamp(0, delays.length - 1)];
    _attempt++;
    _reconnect = Timer(delay, () {
      _reconnect = null;
      if (state.info != null && _socket == null) _connect();
    });
  }

  /// Faz o player seguir a sessão.
  Future<void> _apply() async {
    final info = state.info;
    if (info == null) return;
    await _player.applySession(info.playback, context: info.title);
  }

  void _teardown() {
    _poll?.cancel();
    _sync?.cancel();
    _closeConnection();
    // Saiu da conta: o player deixa a sessão (fora do descarte deste
    // provider, que não pode mexer em outros).
    final player = _attached;
    _attached = null;
    if (player != null) Future.microtask(player.detachGroup);
  }
}
