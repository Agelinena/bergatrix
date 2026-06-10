/// Global, app-wide state for the "Download playlist offline" feature.
///
/// Resilient by design:
///   * Per-track retry with exponential backoff on network errors.
///   * If the device goes offline mid-batch we PAUSE (not fail) and
///     resume when connectivity returns.
///   * The user can cancel from the banner; the loop drops the rest
///     and exits cleanly.
///
/// Previously the PlaylistScreen's _downloadOffline() awaited the whole
/// batch inside a blocking dialog.  Now we kick off [start] from any
/// screen and watch progress through this provider's state.
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../core/api_client.dart';
import '../models/track.dart';
import '../services/offline_service.dart';
import 'connectivity_provider.dart';

part 'offline_download_provider.g.dart';

class OfflineDownloadState {
  /// User-visible playlist name being downloaded; used in the banner.
  final String label;
  final int total;
  final int done;
  final int failed;
  final Track? current;
  final bool active;
  final bool cancelled;
  /// True while we're holding the loop waiting for connectivity to
  /// return.  UI can show "Aguardando conexão…".
  final bool waitingForNetwork;
  final String? lastError;

  const OfflineDownloadState({
    this.label = '',
    this.total = 0,
    this.done = 0,
    this.failed = 0,
    this.current,
    this.active = false,
    this.cancelled = false,
    this.waitingForNetwork = false,
    this.lastError,
  });

  double get progress => total > 0 ? done / total : 0.0;

  OfflineDownloadState copyWith({
    String? label,
    int? total,
    int? done,
    int? failed,
    Track? current,
    bool? active,
    bool? cancelled,
    bool? waitingForNetwork,
    String? lastError,
  }) =>
      OfflineDownloadState(
        label: label ?? this.label,
        total: total ?? this.total,
        done: done ?? this.done,
        failed: failed ?? this.failed,
        current: current ?? this.current,
        active: active ?? this.active,
        cancelled: cancelled ?? this.cancelled,
        waitingForNetwork: waitingForNetwork ?? this.waitingForNetwork,
        lastError: lastError ?? this.lastError,
      );
}

@Riverpod(keepAlive: true)
class OfflineDownload extends _$OfflineDownload {
  @override
  OfflineDownloadState build() {
    // Resume a batch that was interrupted by the app being killed last time.
    // (When _run finishes or is cancelled it clears the persisted batch, so
    // this only fires for a hard kill mid-download — Spotify-style resume.)
    Future.microtask(_maybeResume);
    return const OfflineDownloadState();
  }

  Future<void> _maybeResume() async {
    if (state.active) return;
    final pending = await OfflineService.loadPendingBatch();
    if (pending == null) return;
    debugPrint('[OfflineDownload] resuming persisted batch "${pending.label}" '
        '(${pending.tracks.length} remaining)');
    await start(label: pending.label, tracks: pending.tracks);
  }

  /// Begins a batch download.  Idempotent if already running for the
  /// same playlist label — second calls are dropped silently.
  Future<void> start({
    required String label,
    required List<Track> tracks,
  }) async {
    if (state.active) {
      debugPrint('[OfflineDownload] start ignored: already running '
          '"${state.label}" (${state.done}/${state.total})');
      return;
    }
    if (tracks.isEmpty) return;

    // Persist the batch so it survives an app kill and auto-resumes.
    await OfflineService.savePendingBatch(label, tracks);

    state = OfflineDownloadState(
      label: label,
      total: tracks.length,
      done: 0,
      failed: 0,
      current: tracks.first,
      active: true,
      cancelled: false,
    );

    final client = ref.read(apiClientProvider);
    // Fire-and-forget the work; the provider's state is what the UI watches.
    unawaited(_run(client, label, tracks));
  }

  Future<void> _run(ApiClient client, String label, List<Track> tracks) async {
    try {
      final already = await OfflineService.getDownloadedTracks();
      final alreadyIds = already.map((t) => t.id).toSet();

      for (var i = 0; i < tracks.length; i++) {
        final track = tracks[i];
        if (state.cancelled) {
          debugPrint('[OfflineDownload] cancelled at ${state.done}/${state.total}');
          break;
        }

        // If we're offline, wait until we're back online before
        // attempting this track. The user can still cancel during the
        // wait — we re-check the cancelled flag every poll.
        await _waitForNetwork();
        if (state.cancelled) break;

        state = state.copyWith(current: track);

        if (alreadyIds.contains(track.id)) {
          state = state.copyWith(done: state.done + 1);
        } else {
          final ok = await _downloadWithRetry(client, track);
          if (ok) {
            alreadyIds.add(track.id);
            state = state.copyWith(done: state.done + 1);
          } else {
            state = state.copyWith(failed: state.failed + 1);
          }
        }

        // Shrink the persisted batch to what's still pending so a kill
        // here resumes from the next track, not the start.
        await OfflineService.savePendingBatch(label, tracks.sublist(i + 1));
      }
    } finally {
      // Normal completion or cancel: the in-memory run is over, so forget the
      // persisted batch.  (A hard app-kill skips this finally entirely, which
      // is exactly when we WANT the persisted tail to survive and resume.)
      await OfflineService.clearPendingBatch();
      state = state.copyWith(
        active: false,
        current: null,
        waitingForNetwork: false,
      );
    }
  }

  /// Downloads with up to 3 attempts on transient network errors.
  Future<bool> _downloadWithRetry(ApiClient client, Track track) async {
    const maxAttempts = 3;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      if (state.cancelled) return false;
      try {
        await OfflineService.download(track, client);
        return true;
      } on DioException catch (e) {
        if (!_isTransientNetworkError(e)) {
          // Non-network failure (e.g. 404) — don't retry.
          debugPrint('[OfflineDownload] ${track.id} non-retriable: ${e.type}');
          state = state.copyWith(lastError: '$e');
          return false;
        }
        debugPrint('[OfflineDownload] ${track.id} attempt $attempt/$maxAttempts '
            'failed: ${e.type}; backing off');
        if (attempt < maxAttempts) {
          // Wait either for the backoff window OR for the user to
          // cancel, whichever comes first.
          await _sleepCancellable(Duration(seconds: 2 * attempt));
          // If we lost network during the wait, hold the loop until
          // it returns before retrying.
          await _waitForNetwork();
        } else {
          state = state.copyWith(lastError: '$e');
          return false;
        }
      } catch (e) {
        debugPrint('[OfflineDownload] ${track.id} unexpected: $e');
        state = state.copyWith(lastError: '$e');
        return false;
      }
    }
    return false;
  }

  bool _isTransientNetworkError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionError:
      case DioExceptionType.unknown:
        return true;
      case DioExceptionType.badCertificate:
      case DioExceptionType.badResponse:
      case DioExceptionType.cancel:
        return false;
    }
  }

  /// Suspends the loop until [connectivityProvider] reports online.
  /// Updates state.waitingForNetwork so the banner can show a hint.
  Future<void> _waitForNetwork() async {
    if (ref.read(connectivityProvider)) return;
    state = state.copyWith(waitingForNetwork: true);
    debugPrint('[OfflineDownload] paused — waiting for network');
    while (!state.cancelled) {
      await Future.delayed(const Duration(seconds: 3));
      // Force a refresh in case the system event never fires.
      await ref.read(connectivityProvider.notifier).refresh();
      if (ref.read(connectivityProvider)) {
        state = state.copyWith(waitingForNetwork: false);
        debugPrint('[OfflineDownload] network back — resuming');
        return;
      }
    }
    state = state.copyWith(waitingForNetwork: false);
  }

  /// Like Future.delayed but bails out early if the user cancels.
  Future<void> _sleepCancellable(Duration d) async {
    final deadline = DateTime.now().add(d);
    while (!state.cancelled && DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 250));
    }
  }

  void cancel() {
    if (!state.active) return;
    state = state.copyWith(cancelled: true);
  }

  /// Dismiss the "finished" banner.  Resets the entire state.
  void dismiss() {
    if (state.active) return;
    state = const OfflineDownloadState();
  }
}
