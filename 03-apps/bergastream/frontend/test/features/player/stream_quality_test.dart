import 'dart:async';

import 'package:bergastream/core/platform/app_platform.dart';
import 'package:bergastream/core/storage/key_value_store.dart';
import 'package:bergastream/data/local/database.dart';
import 'package:bergastream/data/models/search_result.dart';
import 'package:bergastream/data/repositories/playback_repository.dart';
import 'package:bergastream/features/auth/session.dart';
import 'package:bergastream/features/downloads/download_manager.dart';
import 'package:bergastream/features/player/audio_engine.dart';
import 'package:bergastream/features/player/player_controller.dart';
import 'package:bergastream/features/settings/preferences.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../app_harness.dart';
import '../../fake_player.dart';

class _Network implements NetworkCheck {
  bool wifi = true;

  @override
  Future<bool> onWifi() async => wifi;

  @override
  Stream<void> get changes => const Stream.empty();
}

void main() {
  late FakeAudioEngine engine;
  late FakePlaybackRepository repo;
  late _Network network;
  late MemoryKeyValueStore store;
  late ProviderContainer container;

  ProviderContainer make() {
    final c = ProviderContainer(
      overrides: [
        audioEngineProvider.overrideWithValue(engine),
        playbackRepositoryProvider.overrideWithValue(repo),
        networkCheckProvider.overrideWithValue(network),
        playerTimingsProvider.overrideWithValue(
          const PlayerTimings(
            pollInterval: Duration.zero,
            rapidChangeDelay: Duration.zero,
          ),
        ),
        playRecorderProvider.overrideWithValue(
          (SearchResult t, {String? playlistId}) {},
        ),
        localDatabaseProvider.overrideWithValue(null),
        appPlatformProvider.overrideWithValue(const AppPlatform.app()),
        keyValueStoreProvider.overrideWithValue(store),
        initialSessionProvider.overrideWithValue(loggedIn),
      ],
    );
    addTearDown(c.dispose);
    c.read(playerProvider);
    return c;
  }

  setUp(() {
    engine = FakeAudioEngine();
    repo = FakePlaybackRepository();
    network = _Network();
    store = MemoryKeyValueStore();
    container = make();
  });

  Future<void> play() async {
    await container
        .read(playerProvider.notifier)
        .playList([song('A')], 0, context: 'Busca');
    await pumpEventQueue();
  }

  test('no Wi-Fi pede o nível do Wi-Fi (padrão: Original)', () async {
    await play();
    expect(repo.streamQualities, ['original']);
    expect(engine.urls.single.queryParameters['quality'], 'original');
  });

  test('em dados móveis pede o nível de dados (padrão: Normal)', () async {
    network.wifi = false;
    await play();
    expect(repo.streamQualities, ['normal']);
  });

  test('a preferência salva vale já ao abrir o app', () async {
    await store.write('prefs.quality_mobile', 'economica');
    container = make();
    network.wifi = false;
    await play();
    expect(repo.streamQualities, ['low']);
  });

  test('mostra o que o servidor entrega no nível tocado', () async {
    repo.serverQualities = {
      'spotify:A': {
        'original': const TrackQuality('FLAC 16/44.1', 40),
        'normal': const TrackQuality('AAC 160', 20),
      },
    };
    await play();
    expect(container.read(playerProvider).quality, 'FLAC 16/44.1');

    network.wifi = false;
    await container
        .read(playerProvider.notifier)
        .playList([song('A')], 0, context: 'Busca');
    await pumpEventQueue();
    expect(container.read(playerProvider).quality, 'AAC 160');
  });

  test('sem informação do servidor, não mostra qualidade', () async {
    await play();
    expect(container.read(playerProvider).quality, isNull);
  });

  group('preferências', () {
    Future<Preferences> load() async {
      final notifier = container.read(preferencesProvider.notifier);
      await notifier.ready;
      return container.read(preferencesProvider);
    }

    test(
      'padrões: Original no Wi-Fi, Normal nos dados, Alta offline',
      () async {
        final p = await load();
        expect(
          [p.wifiQuality, p.mobileQuality, p.offlineQuality],
          [AudioQuality.original, AudioQuality.normal, AudioQuality.alta],
        );
      },
    );

    test('a qualidade única das versões antigas vira a de dados', () async {
      await store.write('prefs.quality', 'baixa');
      container = make();
      final p = await load();
      expect(p.mobileQuality, AudioQuality.economica);
      expect(p.wifiQuality, AudioQuality.original);
    });

    test('cada escolha fica guardada', () async {
      final notifier = container.read(preferencesProvider.notifier);
      await notifier.setWifiQuality(AudioQuality.alta);
      await notifier.setMobileQuality(AudioQuality.economica);
      await notifier.setOfflineQuality(AudioQuality.original);
      container = make();
      final p = await load();
      expect(
        [p.wifiQuality, p.mobileQuality, p.offlineQuality],
        [AudioQuality.alta, AudioQuality.economica, AudioQuality.original],
      );
    });

    test('valores da API', () {
      expect(AudioQuality.values.map((q) => q.api), [
        'original',
        'high',
        'normal',
        'low',
      ]);
    });
  });
}
