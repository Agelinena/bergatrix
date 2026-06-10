// Phase 2 (offline) unit tests.
//
// These cover the dependency-light, pure logic that makes offline robust:
//   * OfflineService.formatBytes               — human-readable sizes
//   * Track JSON round-trip                     — persistence relies on it
//   * resumable batch persistence (save/load/clear) via mocked prefs
//
// Filesystem-backed paths (localPath / downloadedIdsOnDisk / validateAndRepair)
// need a path_provider platform mock and are exercised by manual/integration
// runs; here we lock down everything that can run headless.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bergastream/models/track.dart';
import 'package:bergastream/services/offline_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('OfflineService.formatBytes', () {
    test('zero bytes', () => expect(OfflineService.formatBytes(0), '0 B'));
    test('1.5 KB', () => expect(OfflineService.formatBytes(1536), '1.50 KB'));
    test('5 MB', () => expect(OfflineService.formatBytes(5 * 1024 * 1024), '5.00 MB'));
    test('negative is clamped to 0 B', () => expect(OfflineService.formatBytes(-10), '0 B'));
  });

  group('Track JSON round-trip', () {
    test('preserves id/title/artist/source through encode+decode', () {
      const original = Track(
        id: 'deezer_123',
        title: 'My Song',
        artist: 'My Artist',
        source: 'deezer',
        durationMs: 200000,
      );
      final decoded = Track.fromJson(original.toJson());
      expect(decoded.id, original.id);
      expect(decoded.title, original.title);
      expect(decoded.artist, original.artist);
      expect(decoded.source, original.source);
      expect(decoded.durationMs, original.durationMs);
    });
  });

  group('resumable batch persistence', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    const t1 = Track(id: 'deezer_1', title: 'A', artist: 'X', source: 'deezer');
    const t2 = Track(id: 'deezer_2', title: 'B', artist: 'Y', source: 'deezer');

    test('save then load round-trips label and remaining tracks', () async {
      await OfflineService.savePendingBatch('My Playlist', [t1, t2]);
      final loaded = await OfflineService.loadPendingBatch();
      expect(loaded, isNotNull);
      expect(loaded!.label, 'My Playlist');
      expect(loaded.tracks.map((t) => t.id).toList(), ['deezer_1', 'deezer_2']);
    });

    test('saving an empty remaining list clears the batch', () async {
      await OfflineService.savePendingBatch('P', [t1]);
      await OfflineService.savePendingBatch('P', []);
      expect(await OfflineService.loadPendingBatch(), isNull);
    });

    test('clearPendingBatch removes a persisted batch', () async {
      await OfflineService.savePendingBatch('P', [t1, t2]);
      await OfflineService.clearPendingBatch();
      expect(await OfflineService.loadPendingBatch(), isNull);
    });

    test('load returns null when nothing was persisted', () async {
      expect(await OfflineService.loadPendingBatch(), isNull);
    });
  });
}
