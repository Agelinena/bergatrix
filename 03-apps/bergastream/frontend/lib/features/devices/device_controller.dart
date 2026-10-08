import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/search_result.dart';
import '../../data/repositories/session_repository.dart';
import '../auth/session.dart';
import '../player/play_queue.dart';
import '../player/player_controller.dart';
import '../session/group_session.dart';
import 'device_identity.dart';

/// "Tocar em…" (como o Spotify Connect): os aparelhos da pessoa ficam
/// conectados ao servidor e só o **ativo** toca. Os outros mostram o que ele
/// toca e mandam os comandos para ele. Tocar algo num aparelho o torna o
/// ativo (o anterior para); a lista de aparelhos permite passar a música
/// para outro. Ver `backend/app/devices/routes.py`.

class DeviceInfo {
  const DeviceInfo({
    required this.id,
    required this.name,
    required this.platform,
  });

  factory DeviceInfo.fromJson(Map<String, dynamic> json) => DeviceInfo(
    id: json['id'] as String,
    name: json['name'] as String? ?? 'Aparelho',
    platform: json['platform'] as String? ?? 'web',
  );

  final String id;
  final String name;

  /// `web`, `android`, `windows`, `linux`...
  final String platform;
}

class DevicesState {
  const DevicesState({
    this.connected = false,
    this.myId,
    this.devices = const [],
    this.activeId,
  });

  final bool connected;

  /// Este aparelho.
  final String? myId;
  final List<DeviceInfo> devices;

  /// O que toca (nulo: nenhum).
  final String? activeId;

  DeviceInfo? get active {
    for (final d in devices) {
      if (d.id == activeId) return d;
    }
    return null;
  }

  bool get activeHere => activeId != null && activeId == myId;

  /// Outro aparelho da pessoa está tocando.
  DeviceInfo? get otherActive {
    final a = active;
    return a != null && a.id != myId ? a : null;
  }

  /// Este aparelho pode tocar (nenhum outro é o ativo).
  bool get canPlayHere => otherActive == null;

  DevicesState copyWith({
    bool? connected,
    String? myId,
    List<DeviceInfo>? devices,
    String? activeId,
    bool clearActive = false,
  }) => DevicesState(
    connected: connected ?? this.connected,
    myId: myId ?? this.myId,
    devices: devices ?? this.devices,
    activeId: clearActive ? null : activeId ?? this.activeId,
  );
}

/// Tempos da conexão (os testes desligam os timers).
class DeviceTimings {
  const DeviceTimings({
    this.stateInterval = const Duration(seconds: 5),
    this.keepAlive = const Duration(seconds: 25),
    this.reconnectDelays = const [
      Duration(seconds: 1),
      Duration(seconds: 3),
      Duration(seconds: 10),
      Duration(seconds: 30),
    ],
  });

  /// O ativo reenvia a posição enquanto toca (os outros não se perdem).
  final Duration? stateInterval;
  final Duration? keepAlive;
  final List<Duration> reconnectDelays;
}

final deviceTimingsProvider = Provider<DeviceTimings>(
  (ref) => const DeviceTimings(),
);

/// Abre `wss://servidor/api/devices/ws`.
typedef DeviceSocketFactory = SessionSocket Function({required String server});

Uri deviceSocketUrl(String server) {
  final base = Uri.parse(server);
  var path = base.path;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  return base.replace(
    scheme: base.scheme == 'https' ? 'wss' : 'ws',
    path: '$path/api/devices/ws',
  );
}

final deviceSocketFactoryProvider = Provider<DeviceSocketFactory>(
  (ref) =>
      ({required server}) => WebSessionSocket(deviceSocketUrl(server)),
);

final devicesProvider = NotifierProvider<DeviceController, DevicesState>(
  DeviceController.new,
);

class DeviceController extends Notifier<DevicesState> implements RemoteControl {
  SessionSocket? _socket;
  StreamSubscription<Map<String, dynamic>>? _messages;
  Timer? _keepAlive;
  Timer? _stateTimer;
  Timer? _reconnect;
  int _attempt = 0;
  bool _replaced = false;

  /// Player que este controlador pôs em modo remoto (para soltar no fim).
  PlayerController? _attached;

  static const noConnection = 'Sem conexão com o outro aparelho.';

  PlayerController get _player => ref.read(playerProvider.notifier);
  DeviceTimings get _timings => ref.read(deviceTimingsProvider);

  @override
  DevicesState build() {
    final loggedIn = ref.watch(sessionProvider.select((s) => s.isLoggedIn));
    ref.onDispose(_teardown);
    ref.listen(playerProvider, _onPlayer);
    if (loggedIn) Future.microtask(_connect);
    return const DevicesState();
  }

  // ── RemoteControl (usado pelo player em modo remoto) ──

  @override
  String get deviceName => state.otherActive?.name ?? 'outro aparelho';

  @override
  void command(Map<String, Object?> command) {
    final socket = _socket;
    if (!state.connected || socket == null) {
      _player.showMessage(noConnection);
      return;
    }
    socket.send({'type': 'command', 'command': command});
  }

  // ── Ações da tela "Tocar em…" ──

  /// Toca em [deviceId]: leva a fila e o ponto da música para lá.
  void transfer(String deviceId) {
    final socket = _socket;
    if (!state.connected || socket == null) return;
    final inGroup = ref.read(groupSessionProvider).active;
    if (deviceId == state.myId) {
      if (state.otherActive == null) {
        // Ninguém mais toca: só passa a tocar aqui.
        _claim();
        if (!inGroup &&
            _player.state.current != null &&
            !_player.state.isPlaying) {
          unawaited(_player.togglePlay());
        }
        return;
      }
      socket.send({'type': 'transfer', 'to': deviceId});
      return;
    }
    Map<String, Object?>? payload;
    if (inGroup) {
      payload = {'session': true};
    } else if (state.otherActive == null && _player.state.current != null) {
      // Toca aqui (ou nada toca): esta fila vai para o outro aparelho.
      payload = _player.handoffState();
    }
    socket.send({'type': 'transfer', 'to': deviceId, 'state': ?payload});
  }

  /// A sessão "ouvir junto" começou ou acabou: o modo remoto não vale
  /// dentro dela (lá cada aparelho segue a sessão).
  void sync() {
    if (!ref.mounted) return;
    final other = state.otherActive;
    final group = ref.read(groupSessionProvider.notifier);
    final inGroup = ref.read(groupSessionProvider).active;
    final player = _player;
    if (other != null && !inGroup) {
      _attached = player..attachRemote(this);
    } else {
      player.detachRemote();
      _attached = null;
    }
    player.setPlayingOn(other?.name);
    if (_couldPlay != state.canPlayHere) {
      _couldPlay = state.canPlayHere;
      group.devicesChanged();
    }
  }

  bool _couldPlay = true;

  /// Este aparelho vai tocar (ex.: entrou numa sessão por aqui).
  void claim() => _claim();

  void _claim() {
    if (state.activeHere || !state.connected) return;
    _socket?.send({'type': 'activate'});
    state = state.copyWith(activeId: state.myId);
    sync();
  }

  // ── Conexão ──

  Future<void> _connect() async {
    if (_socket != null || _replaced) return;
    final session = ref.read(sessionProvider);
    final server = session.server;
    if (!session.isLoggedIn || server == null) return;
    final DeviceIdentity identity;
    try {
      identity = await ref.read(deviceIdentityProvider.future);
    } on Object catch (e) {
      debugPrint('Aparelho sem identidade: $e');
      return;
    }
    if (!ref.mounted || _socket != null) return;
    final socket = ref.read(deviceSocketFactoryProvider)(server: server);
    _socket = socket;
    state = state.copyWith(myId: identity.id);
    socket.send({
      'type': 'auth',
      'token': ref.read(sessionProvider.notifier).accessToken ?? '',
      'device': identity.toJson(),
    });
    _messages = socket.messages.listen(
      _onMessage,
      onDone: () => _onClosed(socket),
      onError: (Object e) => debugPrint('Aparelhos: conexão com erro: $e'),
      cancelOnError: false,
    );
  }

  List<DeviceInfo> _parseDevices(Object? raw) => [
    for (final d in raw as List<dynamic>? ?? const [])
      DeviceInfo.fromJson(d as Map<String, dynamic>),
  ];

  void _onMessage(Map<String, dynamic> message) {
    switch (message['type']) {
      case 'hello':
        _attempt = 0;
        state = state.copyWith(
          connected: true,
          myId: message['device_id'] as String?,
          devices: _parseDevices(message['devices']),
          activeId: message['active'] as String?,
          clearActive: message['active'] == null,
        );
        final every = _timings.keepAlive;
        _keepAlive?.cancel();
        if (every != null) {
          _keepAlive = Timer.periodic(
            every,
            (_) => _socket?.send({'type': 'ping', 't0': 0}),
          );
        }
        sync();
        final remote = message['state'];
        if (remote is Map<String, dynamic> && state.otherActive != null) {
          final serverNow = message['server_now'] as int? ?? 0;
          final at = remote['at'] as int? ?? serverNow;
          _applyRemote(remote, ageMs: serverNow - at);
        }
        // Já tocava aqui antes de conectar: avisa os outros.
        if (state.activeId == null && _player.state.isPlaying) _claim();
      case 'devices':
        state = state.copyWith(
          devices: _parseDevices(message['devices']),
          activeId: message['active'] as String?,
          clearActive: message['active'] == null,
        );
        sync();
        _restartStateTimer();
      case 'state':
        final remote = message['state'];
        if (remote is Map<String, dynamic> &&
            message['from'] == state.activeId &&
            state.otherActive != null) {
          _applyRemote(remote);
        }
      case 'command':
        final command = message['command'];
        if (command is Map<String, dynamic>) unawaited(_execute(command));
      case 'handoff':
        // Outro aparelho vai tocar: para aqui e manda a fila e o ponto.
        final payload = ref.read(groupSessionProvider).active
            ? <String, Object?>{'session': true}
            : _player.handoffState();
        _socket?.send({'type': 'handoff_state', 'state': payload});
      case 'play_here':
        state = state.copyWith(activeId: state.myId);
        sync();
        final payload = message['state'];
        final inGroup = ref.read(groupSessionProvider).active;
        if (payload is Map<String, dynamic> && payload['queue'] != null) {
          unawaited(_player.playFromHandoff(payload));
        } else if (!inGroup &&
            _player.state.current != null &&
            !_player.state.isPlaying) {
          unawaited(_player.togglePlay());
        }
      case 'error':
        final text = message['message'] as String?;
        if (text != null) _player.showMessage(text);
    }
  }

  void _applyRemote(Map<String, dynamic> json, {int ageMs = 0}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _player.applyRemoteState(
      RemotePlayerState.fromJson(json, receivedAt: now - ageMs.clamp(0, 60000)),
    );
  }

  /// Comando de outro aparelho: executa aqui (este é o que toca).
  Future<void> _execute(Map<String, dynamic> c) async {
    final p = _player;
    int intOf(String key) => (c[key] as num?)?.toInt() ?? 0;
    switch (c['action']) {
      case 'play_list':
        final tracks = [
          for (final t in c['tracks'] as List<dynamic>? ?? const [])
            SearchResult.fromJson(t as Map<String, dynamic>),
        ];
        if (tracks.isEmpty) return;
        await p.playList(
          tracks,
          intOf('index').clamp(0, tracks.length - 1),
          context: c['context'] as String? ?? 'Outro aparelho',
          playlistId: c['playlist_id'] as String?,
          shuffle: c['shuffle'] as bool?,
        );
      case 'add':
        await p.addToQueue(
          SearchResult.fromJson(c['track'] as Map<String, dynamic>),
        );
      case 'toggle':
        await p.togglePlay();
      case 'next':
        await p.next();
      case 'previous':
        await p.previous(track: c['track'] == true);
      case 'seek':
        await p.seek(Duration(milliseconds: intOf('position_ms')));
      case 'shuffle':
        p.setShuffle(c['value'] == true);
      case 'repeat':
        p.cycleRepeat();
      case 'remove':
        p.removeFromQueue(intOf('uid'));
      case 'clear':
        p.clearQueue();
      case 'reorder_manual':
        p.reorderQueue(intOf('from'), intOf('to'));
      case 'reorder_next':
        p.reorderUpNext(intOf('from'), intOf('to'));
    }
    // A posição muda sem mudar o estado (ex.: buscar): manda de novo.
    _sendState();
  }

  /// O player daqui mudou: assume a vez ao começar a tocar e conta o
  /// estado aos outros aparelhos.
  void _onPlayer(PlayerState? previous, PlayerState next) {
    if (!state.connected || next.playingOn != null) return;
    final started =
        (next.isPlaying || next.isPreparing) &&
        !(previous?.isPlaying ?? false) &&
        !(previous?.isPreparing ?? false);
    if (started && !state.activeHere && state.otherActive == null) _claim();
    if (!state.activeHere) return;
    final changed =
        previous == null ||
        previous.current?.uid != next.current?.uid ||
        previous.status != next.status ||
        previous.shuffle != next.shuffle ||
        previous.repeat != next.repeat ||
        previous.context != next.context ||
        previous.duration != next.duration ||
        !_sameItems(previous.manual, next.manual) ||
        !_sameItems(previous.upNext, next.upNext);
    if (changed) _sendState();
    _restartStateTimer();
  }

  static bool _sameItems(List<QueueItem> a, List<QueueItem> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].uid != b[i].uid) return false;
    }
    return true;
  }

  void _sendState() {
    if (!state.activeHere || !state.connected) return;
    _socket?.send({'type': 'state', 'state': _player.remoteSnapshot()});
  }

  /// Enquanto toca aqui, reenvia a posição de tempos em tempos.
  void _restartStateTimer() {
    final every = _timings.stateInterval;
    final playing = state.activeHere && _player.state.isPlaying;
    if (every == null || !playing) {
      _stateTimer?.cancel();
      _stateTimer = null;
      return;
    }
    _stateTimer ??= Timer.periodic(every, (_) => _sendState());
  }

  void _onClosed(SessionSocket socket) {
    if (!identical(socket, _socket)) return;
    _socket = null;
    _keepAlive?.cancel();
    _stateTimer?.cancel();
    _stateTimer = null;
    unawaited(_messages?.cancel());
    _messages = null;
    if (!ref.mounted) return;
    state = state.copyWith(
      connected: false,
      devices: const [],
      clearActive: true,
    );
    sync();
    switch (socket.closeCode) {
      case 4409:
        // Este aparelho abriu de novo (outra aba): esta conexão fica de fora.
        _replaced = true;
      case 4401:
        unawaited(
          ref.read(sessionProvider.notifier).refreshTokens().then((ok) {
            if (ok) {
              _scheduleReconnect();
            }
          }),
        );
      default:
        _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_reconnect != null || !ref.mounted) return;
    final delays = _timings.reconnectDelays;
    if (delays.isEmpty) return;
    final delay = delays[_attempt.clamp(0, delays.length - 1)];
    _attempt++;
    _reconnect = Timer(delay, () {
      _reconnect = null;
      if (ref.mounted && _socket == null) unawaited(_connect());
    });
  }

  void _teardown() {
    _keepAlive?.cancel();
    _stateTimer?.cancel();
    _reconnect?.cancel();
    unawaited(_messages?.cancel());
    unawaited(_socket?.close());
    _socket = null;
    // Saiu da conta: o player volta a ser daqui (fora do descarte).
    final player = _attached;
    _attached = null;
    if (player != null) {
      Future.microtask(() {
        player
          ..detachRemote()
          ..setPlayingOn(null);
      });
    }
  }
}
