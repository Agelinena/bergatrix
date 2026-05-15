import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/api_client.dart';
import '../services/cast/cast_service.dart';
import 'player_provider.dart';

// ── State ──────────────────────────────────────────────────────────────────

enum CastStatus { idle, discovering, connecting, connected, error }

class CastState {
  final CastStatus status;
  final List<CastDevice> devices;
  final CastDevice? activeDevice;
  final String? errorMessage;

  const CastState({
    this.status = CastStatus.idle,
    this.devices = const [],
    this.activeDevice,
    this.errorMessage,
  });

  bool get isActive => status == CastStatus.connected;
  bool get isBusy =>
      status == CastStatus.discovering || status == CastStatus.connecting;

  CastState copyWith({
    CastStatus? status,
    List<CastDevice>? devices,
    CastDevice? activeDevice,
    bool clearDevice = false,
    String? errorMessage,
    bool clearError = false,
  }) =>
      CastState(
        status: status ?? this.status,
        devices: devices ?? this.devices,
        activeDevice: clearDevice ? null : (activeDevice ?? this.activeDevice),
        errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      );
}

// ── Provider ───────────────────────────────────────────────────────────────

final castProvider = NotifierProvider<CastNotifier, CastState>(CastNotifier.new);

class CastNotifier extends Notifier<CastState> {
  CastService? _service;
  StreamSubscription<CastServiceEvent>? _eventSub;

  @override
  CastState build() {
    ref.onDispose(_dispose);
    return const CastState();
  }

  // ── Discovery ────────────────────────────────────────────────────────────

  Future<void> discover() async {
    if (state.status == CastStatus.discovering) return;
    _service ??= CastService();
    state = state.copyWith(status: CastStatus.discovering, devices: []);

    try {
      final devices = await _service!.discoverDevices(
        timeout: const Duration(seconds: 5),
      );
      state = state.copyWith(status: CastStatus.idle, devices: devices);
    } catch (e) {
      state = state.copyWith(
        status: CastStatus.error,
        errorMessage: 'Erro ao buscar dispositivos: $e',
      );
    }
  }

  // ── Cast ─────────────────────────────────────────────────────────────────

  /// Connects to [device] and starts streaming the currently playing track.
  Future<void> castTo(CastDevice device) async {
    _service ??= CastService();
    _dispose();
    _service = CastService(); // fresh instance

    state = state.copyWith(
      status: CastStatus.connecting,
      activeDevice: device,
      clearError: true,
    );

    await _eventSub?.cancel();
    _eventSub = _service!.events.listen(_onEvent);

    await _service!.connect(device);
  }

  /// Called after CONNECTED — sends the current track URL.
  Future<void> _sendCurrentTrack() async {
    final playerState = ref.read(playerProvider);
    final track = playerState.currentTrack;
    if (track == null) return;

    try {
      final token = await ref.read(apiClientProvider).getToken();
      final streamUrl = ref.read(apiClientProvider).streamUrl(track.id, token: token);
      await _service?.loadMedia(
        streamUrl,
        track.title,
        track.artist,
        track.coverUrl,
      );
    } catch (e) {
      debugPrint('[Cast] sendCurrentTrack error: $e');
    }
  }

  Future<void> pause() => _service?.pause() ?? Future.value();
  Future<void> resume() => _service?.resume() ?? Future.value();


  Future<void> disconnect() async {
    await _service?.stop();
    state = state.copyWith(
      status: CastStatus.idle,
      clearDevice: true,
      clearError: true,
    );
  }

  // ── Event handler ─────────────────────────────────────────────────────────

  void _onEvent(CastServiceEvent event) {
    switch (event) {
      case CastEventConnecting():
        state = state.copyWith(status: CastStatus.connecting);

      case CastEventConnected():
        state = state.copyWith(status: CastStatus.connected, clearError: true);
        _sendCurrentTrack();

      case CastEventDisconnected():
        state = state.copyWith(
          status: CastStatus.idle,
          clearDevice: true,
          clearError: true,
        );

      case CastEventError(:final message):
        state = state.copyWith(
          status: CastStatus.error,
          errorMessage: message,
          clearDevice: true,
        );

      case CastEventMediaStatus():
        break; // could update play/pause status in future
    }
  }

  // ── Cleanup ───────────────────────────────────────────────────────────────

  void _dispose() {
    _eventSub?.cancel();
    _eventSub = null;
    _service?.dispose();
    _service = null;
  }
}
