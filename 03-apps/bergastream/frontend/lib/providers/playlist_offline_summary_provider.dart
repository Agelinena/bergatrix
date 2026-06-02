/// Per-playlist offline summary: how many of its tracks are downloaded
/// on this device.  Used by the LibraryScreen's playlist tile to show
/// a small "5/20 offline" badge / a check icon when 100%.
///
/// Reads the playlist detail from OfflineCache (set after every
/// PlaylistScreen load) so it doesn't trigger extra network calls.
/// If the playlist has never been opened, returns null — UI hides
/// the badge in that case.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/offline_cache.dart';
import 'downloaded_tracks_provider.dart';

class PlaylistOfflineSummary {
  final int downloaded;
  final int total;
  const PlaylistOfflineSummary({required this.downloaded, required this.total});

  double get ratio => total > 0 ? downloaded / total : 0.0;
  bool get isFullyOffline => total > 0 && downloaded == total;
  bool get isPartiallyOffline => downloaded > 0 && downloaded < total;
}

/// Family provider keyed by playlist ID.  Re-runs whenever the
/// device-downloaded set changes (a batch finished, a track was deleted).
final playlistOfflineSummaryProvider =
    FutureProvider.family<PlaylistOfflineSummary?, String>((ref, playlistId) async {
  final downloadedIds = ref.watch(downloadedTracksProvider);

  try {
    final cached = await OfflineCache.getMap('playlist_$playlistId');
    if (cached == null) return null;
    final tracks = cached['tracks'] as List?;
    if (tracks == null || tracks.isEmpty) return null;
    var downloaded = 0;
    for (final pt in tracks) {
      try {
        final m = pt as Map<String, dynamic>;
        final track = m['track'] as Map<String, dynamic>?;
        final tid = track?['id'] as String?;
        if (tid != null && downloadedIds.contains(tid)) downloaded++;
      } catch (_) {}
    }
    return PlaylistOfflineSummary(
      downloaded: downloaded,
      total: tracks.length,
    );
  } catch (e) {
    debugPrint('[PlaylistOfflineSummary] $playlistId error: $e');
    return null;
  }
});
