import 'package:bergastream/core/platform/app_platform.dart';
import 'package:bergastream/core/storage/key_value_store.dart';
import 'package:bergastream/data/local/database.dart';
import 'package:bergastream/data/repositories/playback_repository.dart';
import 'package:bergastream/features/auth/session.dart';
import 'package:bergastream/features/output/output_devices.dart';
import 'package:bergastream/features/output/output_engine.dart';
import 'package:bergastream/features/player/audio_engine.dart';
import 'package:bergastream/features/player/player_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../app_harness.dart';
import '../../fake_player.dart';

void main() {
  late FakeAudioEngine local;
  late FakePlaybackRepository repo;
  late ProviderContainer container;

  PlayerController player() => container.read(playerProvider.notifier);
  PlayerState state() => container.read(playerProvider);

  setUp(() {
    local = FakeAudioEngine();
    repo = FakePlaybackRepository();
    container = ProviderContainer(
      overrides: [
        audioEngineProvider.overrideWithValue(OutputEngine(local)),
        playbackRepositoryProvider.overrideWithValue(repo),
        playerTimingsProvider.overrideWithValue(
          const PlayerTimings(
            pollInterval: Duration.zero,
            rapidChangeDelay: Duration.zero,
            autoSkipDelay: Duration.zero,
            fades: false,
          ),
        ),
        playRecorderProvider.overrideWithValue((t, {playlistId}) {}),
        localDatabaseProvider.overrideWithValue(null),
        appPlatformProvider.overrideWithValue(const AppPlatform.app()),
        keyValueStoreProvider.overrideWithValue(MemoryKeyValueStore()),
        initialSessionProvider.overrideWithValue(loggedIn),
      ],
    );
    addTearDown(container.dispose);
    container.read(playerProvider);
  });

  test(
    'passar para a TV: continua do mesmo ponto, em MP3 320, com título',
    () async {
      await player().playList([song('A'), song('B')], 0, context: 'Busca');
      local.emitPosition(const Duration(seconds: 42));
      await pumpEventQueue();
      final tv = FakeRenderer();
      await player().switchOutput(tv);

      expect(local.playing, isFalse, reason: 'aqui para');
      expect(tv.urls.single.queryParameters['quality'], 'high');
      expect(tv.described, ['A']);
      expect(tv.log, containsAllInOrder(['setUrl', 'seek 42', 'play']));
      expect(state().playingOn, 'TV da sala');
      expect(player().renderer, same(tv));

      // A próxima música também vai para a TV.
      await player().next();
      expect(tv.described, ['A', 'B']);
      expect(tv.urls, hasLength(2));
    },
  );

  test('pausado continua pausado na TV', () async {
    await player().playList([song('A')], 0, context: 'Busca');
    await player().togglePlay();
    final tv = FakeRenderer();
    await player().switchOutput(tv);
    expect(tv.playing, isFalse);
    expect(state().status, PlaybackStatus.pausado);
  });

  test('a TV caiu: volta a tocar aqui e avisa', () async {
    await player().playList([song('A')], 0, context: 'Busca');
    final tv = FakeRenderer(name: 'Sala');
    await player().switchOutput(tv);
    tv.lose();
    await pumpEventQueue();
    await pumpEventQueue();
    expect(player().renderer, isNull);
    expect(tv.disposed, isTrue);
    expect(local.playing, isTrue);
    expect(state().message?.text, 'Sala saiu da rede. Tocando aqui.');
  });

  testWidgets('"Tocar em…" lista Chromecast e TV e transmite', (tester) async {
    final tv = FakeRenderer(name: 'Sala');
    final outputs = FakeOutputPlatform(
      devices: const [
        OutputDevice(id: 'c1', name: 'Sala', kind: 'Chromecast'),
        OutputDevice(id: 'd1', name: '[TV] Quarto', kind: 'DLNA'),
      ],
      renderers: {'c1': tv},
    );
    final c = await pumpBergastream(
      tester,
      size: const Size(400, 1000),
      engine: OutputEngine(FakeAudioEngine()),
      outputs: outputs,
    );
    await tester.tap(find.text('Buscar').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'queen');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bohemian Rhapsody'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Queen · A Night at the Opera'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Tocar em…'));
    await tester.pumpAndSettle();

    expect(outputs.searches, 1, reason: 'procura ao abrir');
    expect(find.text('Na rede'), findsOneWidget);
    expect(find.text('[TV] Quarto'), findsOneWidget);
    await tester.tap(find.text('Sala'));
    await tester.pumpAndSettle();
    expect(c.read(playerProvider.notifier).renderer, same(tv));
    expect(find.text('Tocando em Sala'), findsOneWidget);
  });
}
