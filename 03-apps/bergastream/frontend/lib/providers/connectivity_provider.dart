/// Tracks online/offline status via connectivity_plus.
///
/// Exposes a simple `online` bool through [ConnectivityNotifier].
/// Used by:
///   * The global OfflineBanner widget (top of every screen).
///   * Search to switch into local-only mode.
///   * Library/Home/Playlist to serve cached payloads.
library;

import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart' as cp;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'connectivity_provider.g.dart';

bool _isOnline(List<cp.ConnectivityResult> results) {
  return results.any((r) =>
      r == cp.ConnectivityResult.wifi ||
      r == cp.ConnectivityResult.mobile ||
      r == cp.ConnectivityResult.ethernet ||
      r == cp.ConnectivityResult.vpn);
}

@Riverpod(keepAlive: true)
class Connectivity extends _$Connectivity {
  StreamSubscription<List<cp.ConnectivityResult>>? _sub;
  final cp.Connectivity _conn = cp.Connectivity();

  @override
  bool build() {
    // Optimistic initial value; we'll refine asynchronously.
    _init();
    ref.onDispose(() { _sub?.cancel(); _debounce?.cancel(); });
    return true;
  }

  Timer? _debounce;

  Future<void> _init() async {
    try {
      final initial = await _conn.checkConnectivity();
      state = _isOnline(initial);
      _sub = _conn.onConnectivityChanged.listen((results) {
        final online = _isOnline(results);
        if (state == online) return;
        if (!online) {
          // Debounce "offline" transitions by 2 s to avoid flapping
          // when the device briefly loses signal while switching networks
          // (WiFi → mobile data handoff).
          _debounce?.cancel();
          _debounce = Timer(const Duration(seconds: 2), () {
            if (state) {
              debugPrint('[Connectivity] state changed → OFFLINE');
              state = false;
            }
          });
        } else {
          // Coming back online: update immediately and cancel any pending
          // offline debounce.
          _debounce?.cancel();
          debugPrint('[Connectivity] state changed → ONLINE');
          state = true;
        }
      });
    } catch (e) {
      debugPrint('[Connectivity] init failed (assuming online): $e');
    }
  }

  /// Force a refresh — useful after manual retry from the UI.
  Future<void> refresh() async {
    try {
      final results = await _conn.checkConnectivity();
      state = _isOnline(results);
    } catch (_) {}
  }
}
