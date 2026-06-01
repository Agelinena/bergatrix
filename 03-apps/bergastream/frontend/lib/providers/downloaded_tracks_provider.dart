/// Cached set of track IDs that have been downloaded offline.
///
/// Reads [OfflineService.getDownloadedTracks] once and exposes a
/// `Set<String>` so the playlist rows can do O(1) `contains` lookups.
/// Auto-refreshes whenever a download finishes (the
/// OfflineDownload provider transitions from active=true to false).
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../services/offline_service.dart';
import 'offline_download_provider.dart';

part 'downloaded_tracks_provider.g.dart';

@Riverpod(keepAlive: true)
class DownloadedTracks extends _$DownloadedTracks {
  bool _lastBatchActive = false;

  @override
  Set<String> build() {
    // Watch the OfflineDownload provider: every time a batch finishes
    // we re-scan the offline-tracks list so newly downloaded tracks
    // light up in the playlist UI immediately.
    final dl = ref.watch(offlineDownloadProvider);
    if (_lastBatchActive && !dl.active) {
      // Batch just finished — refresh.
      Future.microtask(refresh);
    }
    _lastBatchActive = dl.active;

    // Kick off the initial load (microtask so we don't fight the build).
    Future.microtask(refresh);
    return const <String>{};
  }

  Future<void> refresh() async {
    try {
      final tracks = await OfflineService.getDownloadedTracks();
      state = tracks.map((t) => t.id).toSet();
    } catch (e) {
      debugPrint('[DownloadedTracks] refresh error: $e');
    }
  }
}
