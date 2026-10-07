import 'package:bergastream/core/platform/app_platform.dart';
import 'package:bergastream/core/storage/key_value_store.dart';
import 'package:bergastream/data/models/playlist_models.dart';
import 'package:bergastream/features/library/library_providers.dart';
import 'package:bergastream/features/playlists/last_played.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

ServerPlaylist p(String id, [String? lastPlayed]) =>
    ServerPlaylist(id: id, name: id, lastPlayedAt: lastPlayed);

void main() {
  group('sortByLastPlayed', () {
    test('última tocada primeiro; nunca tocadas depois, na ordem recebida', () {
      final list = [
        p('nunca1'),
        p('antiga', '2026-10-01T10:00:00Z'),
        p('nunca2'),
        p('recente', '2026-10-07T10:00:00Z'),
      ];
      expect(
        [for (final x in sortByLastPlayed(list, const {})) x.id],
        ['recente', 'antiga', 'nunca1', 'nunca2'],
      );
    });

    test('tocar neste aparelho passa na frente na hora', () {
      final list = [p('a', '2026-10-07T10:00:00Z'), p('b')];
      final local = {'b': DateTime.utc(2026, 10, 7, 11)};
      expect([for (final x in sortByLastPlayed(list, local)) x.id], ['b', 'a']);
    });

    test('vale o mais recente entre servidor e aparelho', () {
      final list = [p('a', '2026-10-07T12:00:00Z'), p('b')];
      final local = {
        'a': DateTime.utc(2026, 10, 1),
        'b': DateTime.utc(2026, 10, 7, 11),
      };
      expect([for (final x in sortByLastPlayed(list, local)) x.id], ['a', 'b']);
    });
  });

  test('a ordenação escolhida na playlist fica guardada', () async {
    final store = MemoryKeyValueStore();
    ProviderContainer open() {
      final c = ProviderContainer(
        overrides: [
          appPlatformProvider.overrideWithValue(const AppPlatform.app()),
          keyValueStoreProvider.overrideWithValue(store),
        ],
      );
      addTearDown(c.dispose);
      c.listen(playlistSortProvider('p1'), (_, _) {});
      return c;
    }

    final first = open();
    await pumpEventQueue();
    expect(first.read(playlistSortProvider('p1')), PlaylistSort.playlist);
    await first
        .read(playlistSortProvider('p1').notifier)
        .set(PlaylistSort.recentes);

    // Outra sessão (saiu e voltou / reabriu o app).
    final second = open();
    await pumpEventQueue();
    expect(second.read(playlistSortProvider('p1')), PlaylistSort.recentes);
    expect(second.read(playlistSortProvider('p2')), PlaylistSort.playlist);
  });

  test('a última tocada neste aparelho fica guardada', () async {
    final store = MemoryKeyValueStore();
    ProviderContainer open() {
      final c = ProviderContainer(
        overrides: [
          appPlatformProvider.overrideWithValue(const AppPlatform.app()),
          keyValueStoreProvider.overrideWithValue(store),
        ],
      );
      addTearDown(c.dispose);
      c.listen(playlistLastPlayedProvider, (_, _) {});
      return c;
    }

    final first = open();
    await first
        .read(playlistLastPlayedProvider.notifier)
        .touch('p9', DateTime.utc(2026, 10, 7));
    final second = open();
    await pumpEventQueue();
    expect(
      second.read(playlistLastPlayedProvider)['p9'],
      DateTime.utc(2026, 10, 7),
    );
  });
}
