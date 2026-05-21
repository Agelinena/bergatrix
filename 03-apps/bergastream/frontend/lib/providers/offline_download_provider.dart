/// Global, app-wide state for the "Download playlist offline" feature.
///
/// Previously the PlaylistScreen's _downloadOffline() awaited the whole
/// batch with a blocking dialog — the user couldn't navigate, search or
/// play anything until every track was on disk.  The dialog was modal so
/// even backgrounding the app paused the download.
///
/// This provider lets us:
///   1. Kick off [start] from PlaylistScreen and return immediately.
///   2. Track progress as a global state — every screen can read it.
///   3. Render a slim, non-modal banner above the player while running.
///   4. Allow the user to cancel without losing the partial download.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../core/api_client.dart';
import '../models/track.dart';
import '../services/offline_service.dart';

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
  final String? lastError;

  const OfflineDownloadState({
    this.label = '',
    this.total = 0,
    this.done = 0,
    this.failed = 0,
    this.current,
    this.active = false,
    this.cancelled = false,
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
        lastError: lastError ?? this.lastError,
      );
}

@Riverpod(keepAlive: true)
class OfflineDownload extends _$OfflineDownload {
  Completer<void>? _cancelCompleter;

  @override
  OfflineDownloadState build() => const OfflineDownloadState();

  /// Begins a batch download.  Idempotent if already running for the
  /// same playlist label — second calls are dropped silently.
  Future<void> start({
    required String label,
    required List<Track> tracks,
  }) async {
    if (state.active) {
      debugPrint('[OfflineDownload] start ignored: already running '
          '"${state.label}" ($done/${state.total})');
      return;
    }
    if (tracks.isEmpty) return;

    _cancelCompleter = Completer<void>();
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
    unawaited(_run(client, tracks));
  }

  Future<void> _run(ApiClient client, List<Track> tracks) async {
    try {
      final already = await OfflineService.getDownloadedTracks();
      final alreadyIds = already.map((t) => t.id).toSet();

      for (final track in tracks) {
        if (state.cancelled) {
          debugPrint('[OfflineDownload] cancelled at ${state.done}/${state.total}');
          break;
        }
        state = state.copyWith(current: track);

        if (alreadyIds.contains(track.id)) {
          state = state.copyWith(done: state.done + 1);
          continue;
        }

        try {
          await OfflineService.download(track, client);
          alreadyIds.add(track.id);
          state = state.copyWith(done: state.done + 1);
        } catch (e) {
          state = state.copyWith(
            failed: state.failed + 1,
            lastError: '$e',
          );
          debugPrint('[OfflineDownload] track ${track.id} failed: $e');
        }
      }
    } finally {
      state = state.copyWith(active: false, current: null);
      _cancelCompleter?.complete();
      _cancelCompleter = null;
    }
  }

  int get done => state.done;

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
