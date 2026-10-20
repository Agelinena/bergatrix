import 'package:bergastream/core/platform/app_platform.dart';
import 'package:bergastream/core/storage/key_value_store.dart';
import 'package:bergastream/data/models/search_result.dart';
import 'package:bergastream/data/repositories/search_history_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

RecentItem artist(String name) => RecentItem(
  kind: RecentKind.artist,
  provider: 'spotify',
  externalId: 'a-$name',
  title: name,
  subtitle: 'Artista',
);

void main() {
  late MemoryKeyValueStore store;
  ProviderContainer make() {
    final c = ProviderContainer(
      overrides: [
        appPlatformProvider.overrideWithValue(const AppPlatform.app()),
        keyValueStoreProvider.overrideWithValue(store),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  setUp(() => store = MemoryKeyValueStore());

  test('guarda o que foi aberto, mais recente primeiro, sem repetir', () async {
    final c = make();
    final h = c.read(searchHistoryProvider.notifier);
    await h.add(artist('Queen'));
    await h.add(artist('Daft Punk'));
    await h.add(artist('Queen'));
    expect(c.read(searchHistoryProvider).map((i) => i.title), [
      'Queen',
      'Daft Punk',
    ]);
  });

  test('música guarda a faixa inteira; playlist guarda o link', () async {
    const track = SearchResult(
      provider: 'spotify',
      externalId: 't1',
      title: 'Bohemian Rhapsody',
      artist: 'Queen',
    );
    await make()
        .read(searchHistoryProvider.notifier)
        .add(
          const RecentItem(
            kind: RecentKind.track,
            provider: 'spotify',
            externalId: 't1',
            title: 'Bohemian Rhapsody',
            subtitle: 'Música · Queen',
            track: track,
          ),
        );
    await make()
        .read(searchHistoryProvider.notifier)
        .add(
          const RecentItem(
            kind: RecentKind.playlist,
            provider: 'spotify',
            externalId: 'p1',
            title: 'Rock Clássico',
            subtitle: 'Playlist',
            url: 'https://open.spotify.com/playlist/p1',
          ),
        );
    final c = make();
    c.read(searchHistoryProvider);
    await pumpEventQueue();
    final items = c.read(searchHistoryProvider);
    expect(items.map((i) => i.kind), [RecentKind.playlist, RecentKind.track]);
    expect(items.last.track?.title, 'Bohemian Rhapsody');
    expect(items.first.url, 'https://open.spotify.com/playlist/p1');
  });

  test('no máximo 20; remover e limpar', () async {
    final c = make();
    final h = c.read(searchHistoryProvider.notifier);
    for (var i = 0; i < 22; i++) {
      await h.add(artist('artista $i'));
    }
    expect(c.read(searchHistoryProvider), hasLength(20));
    await h.remove(c.read(searchHistoryProvider).first);
    expect(c.read(searchHistoryProvider).first.title, 'artista 20');
    await h.clear();
    expect(c.read(searchHistoryProvider), isEmpty);
  });
}
