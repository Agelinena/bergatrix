/// Cached set of track IDs that are available offline.
///
/// The set is built from FILES ACTUALLY ON DISK
/// ([OfflineService.downloadedIdsOnDisk]), not the SharedPreferences index —
/// so the "downloaded" indicator can never disagree with what will really
/// play offline.  On first build it also runs [OfflineService.validateAndRepair]
/// once to prune stale index entries.  Auto-refreshes whenever a download
/// batch finishes (OfflineDownload transitions active=true → false).
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
  bool _validated = false;

  @override
  Set<String> build() {
    // Watch the OfflineDownload provider: every time a batch finishes
    // we re-scan the on-disk set so newly downloaded tracks light up
    // in the UI immediately.
    final dl = ref.watch(offlineDownloadProvider);
    if (_lastBatchActive && !dl.active) {
      Future.microtask(refresh);
    }
    _lastBatchActive = dl.active;

    // First build: self-heal the index (drop entries whose file vanished)
    // before the initial scan, so a stale index never shows a track as
    // downloaded when it isn't.
    Future.microtask(() async {
      if (!_validated) {
        _validated = true;
        await OfflineService.validateAndRepair();
      }
      await refresh();
    });
    return const <String>{};
  }

  Future<void> refresh() async {
    try {
      state = await OfflineService.downloadedIdsOnDisk();
    } catch (e) {
      debugPrint('[DownloadedTracks] refresh error: $e');
    }
  }
}
