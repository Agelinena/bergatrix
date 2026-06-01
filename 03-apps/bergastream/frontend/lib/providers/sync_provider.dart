/// Multi-device sync provider — talks to `/api/sync` over WebSocket.
///
/// Each running BergaStream instance (web, Android APK, desktop) is a
/// "device".  The first device on a user becomes "active" and is the
/// one actually producing audio.  Other devices show a "Tocando em
/// <name>" hint with controls that send remote commands; either side
/// can transfer playback to itself.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/api_client.dart';
import '../core/constants.dart';
import 'auth_provider.dart';

part 'sync_provider.g.dart';

class SyncDevice {
  final String id;
  final String name;
  final String platform; // web|android|windows|linux|macos
  const SyncDevice({required this.id, required this.name, required this.platform});

  factory SyncDevice.fromJson(Map<String, dynamic> json) => SyncDevice(
        id: json['id'] as String,
        name: json['name'] as String? ?? 'Dispositivo',
        platform: json['platform'] as String? ?? 'unknown',
      );
}

class SyncState {
  final bool connected;
  final String? deviceId;
  final String? activeDeviceId;
  final List<SyncDevice> devices;
  final Map<String, dynamic> sharedState;

  const SyncState({
    this.connected = false,
    this.deviceId,
    this.activeDeviceId,
    this.devices = const [],
    this.sharedState = const {},
  });

  bool get isActiveDevice => deviceId != null && deviceId == activeDeviceId;
  SyncDevice? get activeDevice =>
      devices.firstWhere((d) => d.id == activeDeviceId, orElse: () => const SyncDevice(id: '', name: '', platform: ''));

  SyncState copyWith({
    bool? connected,
    String? deviceId,
    String? activeDeviceId,
    List<SyncDevice>? devices,
    Map<String, dynamic>? sharedState,
  }) =>
      SyncState(
        connected: connected ?? this.connected,
        deviceId: deviceId ?? this.deviceId,
        activeDeviceId: activeDeviceId ?? this.activeDeviceId,
        devices: devices ?? this.devices,
        sharedState: sharedState ?? this.sharedState,
      );
}

@Riverpod(keepAlive: true)
class Sync extends _$Sync {
  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _pingTimer;
  String? _deviceId;
  String? _deviceName;
  String? _platform;
  bool _disposed = false;

  /// Where on the server we connect.  ws:// or wss:// derived from the
  /// configured API base URL.
  String _wsUrl(String token) {
    var base = kApiBaseUrl;
    if (base.startsWith('https://')) {
      base = 'wss://' + base.substring(8);
    } else if (base.startsWith('http://')) {
      base = 'ws://' + base.substring(7);
    }
    return '$base/api/sync?token=$token';
  }

  @override
  SyncState build() {
    ref.onDispose(() {
      _disposed = true;
      _disconnect();
    });
    // Auto-(re)connect whenever the auth state flips to authenticated.
    ref.listen<AsyncValue<dynamic>>(authProvider, (prev, next) {
      final wasAuthed = prev?.valueOrNull != null;
      final isAuthed = next.valueOrNull != null;
      if (!wasAuthed && isAuthed) {
        connect();
      } else if (wasAuthed && !isAuthed) {
        _disconnect();
      }
    });
    return const SyncState();
  }

  Future<void> connect() async {
    if (_channel != null) return; // already connected
    final client = ref.read(apiClientProvider);
    final token = await client.getToken();
    if (token == null) return;

    await _ensureDeviceIdentity();

    try {
      _channel = WebSocketChannel.connect(Uri.parse(_wsUrl(token)));
    } catch (e) {
      debugPrint('[sync] connect failed: $e');
      _scheduleReconnect();
      return;
    }

    _sub = _channel!.stream.listen(
      _onMessage,
      onError: (e) {
        debugPrint('[sync] socket error: $e');
        _scheduleReconnect();
      },
      onDone: () {
        debugPrint('[sync] socket closed');
        if (!_disposed) _scheduleReconnect();
      },
    );

    // Hello handshake.
    _send({
      'type': 'hello',
      'device': {
        'id': _deviceId,
        'name': _deviceName,
        'platform': _platform,
      },
    });

    // Heartbeat ping every 30 s so idle connections don't get dropped
    // by proxies.
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _send({'type': 'ping'});
    });

    state = state.copyWith(connected: true, deviceId: _deviceId);
  }

  void _disconnect() {
    _pingTimer?.cancel();
    _pingTimer = null;
    _sub?.cancel();
    _sub = null;
    try {
      _channel?.sink.close();
    } catch (_) {}
    _channel = null;
    state = state.copyWith(connected: false, activeDeviceId: null, devices: const []);
  }

  void _scheduleReconnect() {
    _disconnect();
    if (_disposed) return;
    Future.delayed(const Duration(seconds: 5), () {
      if (!_disposed && ref.read(authProvider).valueOrNull != null) connect();
    });
  }

  // ── Public API ─────────────────────────────────────────────────────────

  /// Active device announces its current playback state to peers.
  /// Throttled — call at most every few seconds while playing.
  void publishState(Map<String, dynamic> playerState) {
    if (!state.connected) return;
    _send({'type': 'state', 'state': playerState});
    state = state.copyWith(sharedState: playerState);
  }

  /// Remote command to whichever device is currently active.
  void sendCommand(String command, [Map<String, dynamic>? args]) {
    if (!state.connected) return;
    _send({
      'type': 'command',
      'command': command,
      if (args != null) 'args': args,
    });
  }

  /// Take over playback on this device (or transfer to another by id).
  void transferTo(String deviceId) {
    if (!state.connected) return;
    _send({'type': 'transfer', 'to_device_id': deviceId});
  }

  void takeControl() {
    final my = _deviceId;
    if (my != null) transferTo(my);
  }

  // ── Internal ───────────────────────────────────────────────────────────

  void _send(Map<String, dynamic> payload) {
    try {
      _channel?.sink.add(jsonEncode(payload));
    } catch (e) {
      debugPrint('[sync] send failed: $e');
    }
  }

  void _onMessage(dynamic raw) {
    try {
      final msg = jsonDecode(raw as String) as Map<String, dynamic>;
      final type = msg['type'] as String?;
      switch (type) {
        case 'snapshot':
          final devices = ((msg['devices'] as List?) ?? const [])
              .map((d) => SyncDevice.fromJson(d as Map<String, dynamic>))
              .toList();
          state = state.copyWith(
            devices: devices,
            activeDeviceId: msg['active_device_id'] as String?,
            sharedState: (msg['state'] as Map<String, dynamic>?) ?? const {},
          );
        case 'devices':
          final devices = ((msg['devices'] as List?) ?? const [])
              .map((d) => SyncDevice.fromJson(d as Map<String, dynamic>))
              .toList();
          state = state.copyWith(
            devices: devices,
            activeDeviceId: msg['active_device_id'] as String?,
          );
        case 'state':
          final s = msg['state'] as Map<String, dynamic>?;
          if (s != null) state = state.copyWith(sharedState: s);
        case 'transferred':
          state = state.copyWith(activeDeviceId: msg['to_device_id'] as String?);
        case 'command':
          // Forwarded remote command — the player_provider listens to
          // this via `pendingCommand` callbacks.  See applyRemoteCommand.
          final cmd = msg['command'] as String?;
          if (cmd != null) _remoteCommandHandler?.call(cmd, (msg['args'] as Map<String, dynamic>?) ?? const {});
      }
    } catch (e) {
      debugPrint('[sync] parse error: $e');
    }
  }

  // ── Device identity ────────────────────────────────────────────────────

  /// Generates (and persists) a stable id and human-readable name +
  /// platform for this install.
  Future<void> _ensureDeviceIdentity() async {
    if (_deviceId != null) return;
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString('sync_device_id');
    if (id == null) {
      // 16 hex chars, derived from a fresh DateTime — good enough.
      final ts = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
      id = ts.padLeft(16, '0').substring(ts.length > 16 ? ts.length - 16 : 0);
      await prefs.setString('sync_device_id', id);
    }
    _deviceId = id;
    _platform = _platformLabel();
    _deviceName = await _readableDeviceName();
  }

  String _platformLabel() {
    if (kIsWeb) return 'web';
    try {
      if (Platform.isAndroid) return 'android';
      if (Platform.isIOS) return 'ios';
      if (Platform.isWindows) return 'windows';
      if (Platform.isLinux) return 'linux';
      if (Platform.isMacOS) return 'macos';
    } catch (_) {}
    return 'unknown';
  }

  Future<String> _readableDeviceName() async {
    try {
      final info = DeviceInfoPlugin();
      if (kIsWeb) {
        final web = await info.webBrowserInfo;
        return '${web.browserName.name} (web)';
      } else if (Platform.isAndroid) {
        final a = await info.androidInfo;
        return '${a.manufacturer} ${a.model}';
      } else if (Platform.isWindows) {
        final w = await info.windowsInfo;
        return w.computerName;
      } else if (Platform.isLinux) {
        final l = await info.linuxInfo;
        return l.prettyName;
      } else if (Platform.isMacOS) {
        final m = await info.macOsInfo;
        return m.computerName;
      } else if (Platform.isIOS) {
        final i = await info.iosInfo;
        return i.name;
      }
    } catch (e) {
      debugPrint('[sync] device name failed: $e');
    }
    return 'Dispositivo';
  }

  /// Hook used by the player_provider so it can react to remote
  /// commands.  See `Player.bindSyncCommands()`.
  void Function(String command, Map<String, dynamic> args)? _remoteCommandHandler;

  void setRemoteCommandHandler(
      void Function(String, Map<String, dynamic>)? handler) {
    _remoteCommandHandler = handler;
  }
}
