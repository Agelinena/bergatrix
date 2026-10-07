import 'package:bergastream/core/platform/app_platform.dart';
import 'package:bergastream/core/storage/key_value_store.dart';
import 'package:bergastream/data/repositories/search_history_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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

  test('mais recentes primeiro, sem repetir (ignora maiúsculas)', () async {
    final c = make();
    final h = c.read(searchHistoryProvider.notifier);
    await h.add('queen');
    await h.add('daft punk');
    await h.add('Queen ');
    expect(c.read(searchHistoryProvider), ['Queen', 'daft punk']);
  });

  test('guarda no máximo 10 e ignora vazio', () async {
    final c = make();
    final h = c.read(searchHistoryProvider.notifier);
    for (var i = 0; i < 12; i++) {
      await h.add('termo $i');
    }
    await h.add('   ');
    final list = c.read(searchHistoryProvider);
    expect(list, hasLength(10));
    expect(list.first, 'termo 11');
  });

  test('persiste entre aberturas', () async {
    await make().read(searchHistoryProvider.notifier).add('lofi');
    final c = make();
    c.read(searchHistoryProvider);
    await pumpEventQueue();
    expect(c.read(searchHistoryProvider), ['lofi']);
  });
}
