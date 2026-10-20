import 'dart:async';

import 'package:bergastream/core/platform/app_platform.dart';
import 'package:bergastream/core/storage/key_value_store.dart';
import 'package:bergastream/data/local/database.dart';
import 'package:bergastream/data/models/search_result.dart';
import 'package:bergastream/features/auth/session.dart';
import 'package:bergastream/data/repositories/playback_repository.dart';
import 'package:audio_service/audio_service.dart';
import 'package:bergastream/features/player/audio_engine.dart';
import 'package:bergastream/features/player/media_notification.dart';
import 'package:bergastream/features/player/play_queue.dart';
import 'package:bergastream/features/player/player_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:bergastream/features/playlists/last_played.dart';
import 'package:bergastream/features/playlists/playlist_shuffle.dart';
import 'package:bergastream/features/settings/preferences.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../app_harness.dart';
import '../../fake_player.dart';

void main() {
  late FakeAudioEngine engine;
  late FakePlaybackRepository repo;
  late List<String> recorded;
  late List<String?> recordedPlaylists;
  late ProviderContainer container;

  PlayerController controller() => container.read(playerProvider.notifier);
  PlayerState state() => container.read(playerProvider);

  setUp(() {
    engine = FakeAudioEngine();
    repo = FakePlaybackRepository();
    recorded = [];
    recordedPlaylists = [];
    container = ProviderContainer(
      overrides: [
        audioEngineProvider.overrideWithValue(engine),
        playbackRepositoryProvider.overrideWithValue(repo),
        playerTimingsProvider.overrideWithValue(
          const PlayerTimings(
            pollInterval: Duration.zero,
            rapidChangeDelay: Duration.zero,
            autoSkipDelay: Duration.zero,
            fades: false,
          ),
        ),
        playRecorderProvider.overrideWithValue((
          SearchResult t, {
          String? playlistId,
        }) {
          recorded.add(t.title);
          recordedPlaylists.add(playlistId);
        }),
        localDatabaseProvider.overrideWithValue(null),
        appPlatformProvider.overrideWithValue(const AppPlatform.app()),
        keyValueStoreProvider.overrideWithValue(MemoryKeyValueStore()),
        initialSessionProvider.overrideWithValue(loggedIn),
      ],
    );
    addTearDown(container.dispose);
    container.read(playerProvider); // inicia as assinaturas do motor
  });

  final abc = [song('A'), song('B'), song('C')];

  /// A faixa toca até perto do fim e acaba (sem a posição, "acabou" no
  /// começo é stream cortado, não fim de música).
  void finish() {
    engine.emitPosition(const Duration(seconds: 199));
    engine.complete();
  }

  test('tocar: prepara no servidor, pega o stream com token e toca', () async {
    await controller().playList(abc, 0, context: 'Busca');
    expect(repo.prepared, ['A']);
    expect(engine.urls.single.queryParameters['t'], 'x');
    expect(engine.playing, isTrue);
    expect(state().status, PlaybackStatus.tocando);
    expect(state().current!.track.title, 'A');
    expect(state().context, 'Busca');
    expect(state().upNext.map((i) => i.track.title), ['B', 'C']);
  });

  test('espera o download no servidor antes de tocar ("Baixando…")', () async {
    repo
      ..initial = TrackReadiness.baixando
      ..statuses = [TrackReadiness.baixando, TrackReadiness.pronta];
    final statuses = <PlaybackStatus>[];
    container.listen(playerProvider, (_, s) => statuses.add(s.status));
    await controller().playList(abc, 0, context: 'Busca');
    expect(repo.statusCalls, 2);
    expect(statuses.first, PlaybackStatus.preparando);
    expect(state().status, PlaybackStatus.tocando);
  });

  test('falha no servidor: erro com aviso "Não foi possível tocar"', () async {
    repo
      ..initial = TrackReadiness.baixando
      ..statuses = [TrackReadiness.erro];
    await controller().playList(abc, 0, context: 'Busca');
    expect(state().status, PlaybackStatus.erro);
    expect(state().message!.text, PlayerController.notPlayable);
    expect(engine.playing, isFalse);
  });

  test('trocar de faixa durante o preparo descarta a anterior', () async {
    repo.gate = Completer<void>();
    final first = controller().playList(abc, 0, context: 'Busca');
    await Future<void>.delayed(Duration.zero);
    final second = controller().playList([song('Z')], 0, context: 'Busca');
    repo.gate!.complete();
    await Future.wait([first, second]);
    expect(engine.urls, hasLength(1));
    expect(engine.urls.single.path, contains('id-Z'));
    expect(state().current!.track.title, 'Z');
  });

  test('ao acabar, toca a sua fila antes da automática', () async {
    await controller().playList(abc, 0, context: 'Busca');
    await controller().addToQueue(song('X'));
    finish();
    await pumpEventQueue();
    expect(state().current!.track.title, 'X');
    finish();
    await pumpEventQueue();
    expect(state().current!.track.title, 'B');
  });

  test('fim de tudo: para (repetir desligado)', () async {
    await controller().playList([song('A')], 0, context: 'Busca');
    finish();
    await pumpEventQueue();
    expect(state().status, PlaybackStatus.parado);
    expect(state().current!.track.title, 'A');
  });

  test('repetir uma faixa: ao acabar recomeça a mesma', () async {
    await controller().playList(abc, 0, context: 'Busca');
    controller()
      ..cycleRepeat()
      ..cycleRepeat();
    expect(state().repeat, PlayerRepeat.umaFaixa);
    expect(state().message!.text, 'Repetindo esta música');
    finish();
    await pumpEventQueue();
    expect(state().current!.track.title, 'A');
    expect(engine.log.last, 'play');
    expect(engine.log, contains('seek 0'));
    expect(repo.prepared, ['A']);
  });

  test('anterior com mais de 3 s volta ao início da faixa', () async {
    await controller().playList(abc, 0, context: 'Busca');
    await controller().next();
    engine.currentPosition = const Duration(seconds: 10);
    await controller().previous();
    expect(state().current!.track.title, 'B');
    expect(engine.log.last, 'seek 0');
  });

  test('anterior no começo volta à faixa anterior', () async {
    await controller().playList(abc, 0, context: 'Busca');
    await controller().next();
    engine.currentPosition = const Duration(seconds: 1);
    await controller().previous();
    expect(state().current!.track.title, 'A');
  });

  test('adicionar à fila com nada tocando começa a tocar', () async {
    await controller().addToQueue(song('X'));
    expect(state().current!.track.title, 'X');
    expect(state().status, PlaybackStatus.tocando);
    expect(state().context, 'Sua fila');
  });

  test('pausar e continuar', () async {
    await controller().playList(abc, 0, context: 'Busca');
    await controller().togglePlay();
    expect(state().status, PlaybackStatus.pausado);
    expect(engine.playing, isFalse);
    await controller().togglePlay();
    expect(state().status, PlaybackStatus.tocando);
  });

  test('conta no histórico uma vez, ao passar de 30 s', () async {
    await controller().playList(abc, 0, context: 'Busca');
    engine.emitDuration(const Duration(minutes: 5));
    engine.emitPosition(const Duration(seconds: 29));
    await pumpEventQueue();
    expect(recorded, isEmpty);
    engine.emitPosition(const Duration(seconds: 31));
    engine.emitPosition(const Duration(seconds: 45));
    await pumpEventQueue();
    expect(recorded, ['A']);
  });

  test('tocada de uma playlist: a reprodução conta para ela', () async {
    await controller().playList(abc, 0, context: 'Roadtrip', playlistId: 'p1');
    engine.emitDuration(const Duration(minutes: 5));
    engine.emitPosition(const Duration(seconds: 31));
    await pumpEventQueue();
    expect(recordedPlaylists, ['p1']);
    expect(
      container.read(playlistLastPlayedProvider).containsKey('p1'),
      isTrue,
    );
  });

  test('fora de playlist: sem playlist no histórico', () async {
    await controller().playList(abc, 0, context: 'Busca');
    engine.emitDuration(const Duration(minutes: 5));
    engine.emitPosition(const Duration(seconds: 31));
    await pumpEventQueue();
    expect(recordedPlaylists, [null]);
  });

  test('faixa curta conta ao passar da metade', () async {
    await controller().playList(abc, 0, context: 'Busca');
    engine.emitDuration(const Duration(seconds: 40));
    engine.emitPosition(const Duration(seconds: 21));
    await pumpEventQueue();
    expect(recorded, ['A']);
  });

  test('buscar por fração usa a duração do áudio', () async {
    await controller().playList(abc, 0, context: 'Busca');
    engine.emitDuration(const Duration(seconds: 200));
    await pumpEventQueue();
    await controller().seekFraction(0.5);
    expect(engine.log.last, 'seek 100');
  });

  test(
    'cliques rápidos: resposta atrasada da faixa anterior não toca',
    () async {
      // A demora no servidor; B fica pronta antes; A responde depois.
      repo.gates['A'] = Completer<void>();
      final first = controller().playList([song('A')], 0, context: 'Busca');
      await pumpEventQueue();
      await controller().playList([song('B')], 0, context: 'Busca');
      expect(engine.urls.single.path, contains('id-B'));
      repo.gates['A']!.complete();
      await first;
      await pumpEventQueue();
      expect(engine.urls, hasLength(1), reason: 'A não pode carregar depois');
      expect(state().current!.track.title, 'B');
      expect(state().status, PlaybackStatus.tocando);
    },
  );

  test('reabrir o app: continua pausado na mesma música e posição', () async {
    await controller().playList(abc, 1, context: 'Roadtrip', playlistId: 'p1');
    engine.emitDuration(const Duration(minutes: 3));
    await controller().seek(const Duration(seconds: 42));
    await controller().togglePlay(); // pausa (guarda a posição)
    await pumpEventQueue();

    // "Fecha" o app: novo container com o mesmo armazenamento.
    final store = container.read(keyValueStoreProvider);
    final engine2 = FakeAudioEngine();
    final reopened = ProviderContainer(
      overrides: [
        audioEngineProvider.overrideWithValue(engine2),
        playbackRepositoryProvider.overrideWithValue(repo),
        playerTimingsProvider.overrideWithValue(
          const PlayerTimings(
            pollInterval: Duration.zero,
            rapidChangeDelay: Duration.zero,
            autoSkipDelay: Duration.zero,
            fades: false,
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
    addTearDown(reopened.dispose);
    reopened.read(playerProvider);
    await pumpEventQueue();
    final restored = reopened.read(playerProvider);
    expect(restored.current!.track.title, 'B');
    expect(restored.status, PlaybackStatus.pausado);
    expect(restored.context, 'Roadtrip');
    expect(engine2.log, isEmpty); // nada carregado até tocar

    await reopened.read(playerProvider.notifier).togglePlay();
    await pumpEventQueue();
    expect(engine2.log, containsAllInOrder(['setUrl', 'seek 42', 'play']));
    expect(reopened.read(playerProvider).status, PlaybackStatus.tocando);
  });

  test(
    'aleatório no player fica guardado na playlist que está tocando',
    () async {
      await controller().playList(
        abc,
        0,
        context: 'Roadtrip',
        playlistId: 'p1',
      );
      controller().toggleShuffle();
      expect(container.read(playlistShuffleProvider('p1')), isTrue);
      // Tocar outra lista com o aleatório dela não mexe na p1.
      await controller().playList(
        abc,
        0,
        context: 'Outra',
        playlistId: 'p2',
        shuffle: false,
      );
      expect(state().shuffle, isFalse);
      expect(container.read(playlistShuffleProvider('p1')), isTrue);
    },
  );

  group('segundo plano e downloads', () {
    test('trocando de música, o Android continua vendo "tocando"', () async {
      final handler = BergaAudioHandler();
      final c = ProviderContainer(
        overrides: [
          audioEngineProvider.overrideWithValue(engine),
          playbackRepositoryProvider.overrideWithValue(repo),
          playerTimingsProvider.overrideWithValue(
            const PlayerTimings(
              pollInterval: Duration.zero,
              rapidChangeDelay: Duration.zero,
              autoSkipDelay: Duration.zero,
              fades: false,
            ),
          ),
          playRecorderProvider.overrideWithValue(
            (SearchResult t, {String? playlistId}) {},
          ),
          mediaNotificationProvider.overrideWithValue(handler),
          localDatabaseProvider.overrideWithValue(null),
          appPlatformProvider.overrideWithValue(const AppPlatform.app()),
          keyValueStoreProvider.overrideWithValue(MemoryKeyValueStore()),
          initialSessionProvider.overrideWithValue(loggedIn),
        ],
      );
      addTearDown(c.dispose);
      final ctl = c.read(playerProvider.notifier);
      repo.gate = Completer<void>();
      final loading = ctl.playList(abc, 0, context: 'Busca');
      await pumpEventQueue();
      // Preparando no servidor: serviço em primeiro plano (CPU acordada).
      expect(c.read(playerProvider).status, PlaybackStatus.preparando);
      expect(handler.playbackState.value.playing, isTrue);
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.loading,
      );
      repo.gate!.complete();
      await loading;
      expect(handler.playbackState.value.playing, isTrue);
      // Pausado de verdade: aí sim sai do primeiro plano.
      await ctl.togglePlay();
      expect(handler.playbackState.value.playing, isFalse);
    });

    test('depois de 8 s pede ao servidor só a próxima', () async {
      await controller().playList(abc, 0, context: 'Busca');
      engine.emitDuration(const Duration(minutes: 4));
      repo.prepared.clear();
      engine.emitPosition(const Duration(seconds: 5));
      await pumpEventQueue();
      expect(repo.prepared, isEmpty);
      engine.emitPosition(const Duration(seconds: 9));
      engine.emitPosition(const Duration(seconds: 40));
      await pumpEventQueue();
      expect(repo.prepared, ['B']); // só a próxima, uma vez
    });

    test('pedido da próxima falhou: tenta de novo', () async {
      await controller().playList(abc, 0, context: 'Busca');
      engine.emitDuration(const Duration(minutes: 4));
      repo
        ..prepared.clear()
        ..failPrepare = true;
      engine.emitPosition(const Duration(seconds: 9));
      await pumpEventQueue();
      expect(repo.prepared, ['B']);
      repo.failPrepare = false;
      engine.emitPosition(const Duration(seconds: 10));
      await pumpEventQueue();
      expect(repo.prepared, [
        'B',
      ], reason: 'espera o intervalo de nova tentativa');
    });

    test('faixa curta: pede a próxima na metade', () async {
      await controller().playList(abc, 0, context: 'Busca');
      engine.emitDuration(const Duration(seconds: 30));
      repo.prepared.clear();
      engine.emitPosition(const Duration(seconds: 16));
      await pumpEventQueue();
      expect(repo.prepared, ['B']);
    });

    test('vários toques rápidos: só a última vai para o servidor', () async {
      final c = ProviderContainer(
        parent: container,
        overrides: [
          playerTimingsProvider.overrideWithValue(
            const PlayerTimings(
              pollInterval: Duration.zero,
              rapidChangeDelay: Duration(milliseconds: 50),
            ),
          ),
        ],
      );
      addTearDown(c.dispose);
      final ctl = c.read(playerProvider.notifier);
      final first = ctl.playList([song('A')], 0, context: 'Busca');
      await pumpEventQueue();
      final second = ctl.playList([song('B')], 0, context: 'Busca');
      final third = ctl.playList([song('C')], 0, context: 'Busca');
      await Future.wait([first, second, third]);
      // A primeira foi direto (nada antes); B foi "passada" e não baixou.
      expect(repo.prepared, ['A', 'C']);
      expect(c.read(playerProvider).current!.track.title, 'C');
    });
  });

  group('stream cortado e pausas do sistema', () {
    test('"acabou" longe do fim: retoma do ponto, não pula a música', () async {
      await controller().playList(abc, 0, context: 'Busca');
      engine
        ..emitDuration(const Duration(seconds: 200))
        ..emitPosition(const Duration(seconds: 73));
      engine.log.clear();
      engine.complete();
      await pumpEventQueue();
      expect(state().current!.track.title, 'A');
      expect(engine.log, ['setUrl', 'seek 73', 'play']);
      expect(engine.urls, hasLength(2), reason: 'URL nova (token novo)');
    });

    test(
      'cortou de novo e de novo: depois de 2 retomadas, segue a fila',
      () async {
        await controller().playList(abc, 0, context: 'Busca');
        engine.emitPosition(const Duration(seconds: 50));
        for (var i = 0; i < 3; i++) {
          engine.complete();
          await pumpEventQueue();
        }
        expect(state().current!.track.title, 'B');
      },
    );

    test('acabou perto do fim: segue a fila', () async {
      await controller().playList(abc, 0, context: 'Busca');
      engine.emitPosition(const Duration(seconds: 199));
      engine.complete();
      await pumpEventQueue();
      expect(state().current!.track.title, 'B');
    });

    test('erro no meio da faixa: retoma do ponto', () async {
      await controller().playList(abc, 0, context: 'Busca');
      engine.emitPosition(const Duration(seconds: 30));
      engine.log.clear();
      engine.emitError(Exception('conexão caiu'));
      await pumpEventQueue();
      expect(engine.log, ['setUrl', 'seek 30', 'play']);
      expect(state().status, PlaybackStatus.tocando);
    });

    test('Bluetooth desconectou (sistema pausou): mostra pausado', () async {
      await controller().playList(abc, 0, context: 'Busca');
      expect(state().status, PlaybackStatus.tocando);
      engine.systemPause();
      await pumpEventQueue();
      expect(state().status, PlaybackStatus.pausado);
      // Um toque no play volta a tocar (antes precisava de dois).
      await controller().togglePlay();
      expect(engine.playing, isTrue);
      expect(state().status, PlaybackStatus.tocando);
    });

    test('fila tocando sozinha: música que não toca é pulada', () async {
      await controller().playList(abc, 0, context: 'Busca');
      repo.failTitles.add('B');
      finish(); // A acabou; B não toca
      for (var i = 0; i < 4; i++) {
        await pumpEventQueue();
      }
      expect(state().current!.track.title, 'C');
      expect(state().status, PlaybackStatus.tocando);
    });

    test('música escolhida que não toca: não pula sozinha', () async {
      repo.failPrepare = true;
      await controller().playList(abc, 1, context: 'Busca');
      await pumpEventQueue();
      expect(state().current!.track.title, 'B');
      expect(state().status, PlaybackStatus.erro);
    });
  });

  group('fila, volume e fades', () {
    /// Player com os fades ligados (os outros testes desligam).
    ProviderContainer fading() {
      final c = ProviderContainer(
        overrides: [
          audioEngineProvider.overrideWithValue(engine),
          playbackRepositoryProvider.overrideWithValue(repo),
          playerTimingsProvider.overrideWithValue(
            const PlayerTimings(
              pollInterval: Duration.zero,
              rapidChangeDelay: Duration.zero,
              autoSkipDelay: Duration.zero,
            ),
          ),
          playRecorderProvider.overrideWithValue(
            (SearchResult t, {String? playlistId}) {},
          ),
          localDatabaseProvider.overrideWithValue(null),
          appPlatformProvider.overrideWithValue(const AppPlatform.app()),
          keyValueStoreProvider.overrideWithValue(MemoryKeyValueStore()),
          initialSessionProvider.overrideWithValue(loggedIn),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('tocar numa música da fila pula direto para ela', () async {
      await controller().playList(abc, 0, context: 'Busca');
      final c = state().upNext[1];
      await controller().jumpTo(c.uid);
      expect(state().current!.track.title, 'C');
      expect(state().upNext, isEmpty);
      expect(engine.playing, isTrue);
    });

    test('normalização: música alta é abaixada até -14 LUFS', () async {
      repo.serverLoudness = {
        song('A').id: const TrackLoudness(-8, -0.5), // 6 dB acima do alvo
        song('B').id: const TrackLoudness(-18, -3), // abaixo: não sobe
      };
      await controller().playList(abc, 0, context: 'Busca');
      expect(engine.volume, closeTo(0.501, 0.01));
      await controller().next();
      expect(engine.volume, 1.0);
    });

    test('normalização desligada: volume cheio', () async {
      repo.serverLoudness = {song('A').id: const TrackLoudness(-8, -0.5)};
      await container
          .read(preferencesProvider.notifier)
          .setNormalizeVolume(false);
      await controller().playList(abc, 0, context: 'Busca');
      expect(engine.volume, 1.0);
    });

    test('volume da barra multiplica o da normalização', () async {
      repo.serverLoudness = {song('A').id: const TrackLoudness(-8, -0.5)};
      await controller().playList(abc, 0, context: 'Busca');
      controller().setVolume(0.5);
      expect(engine.volume, closeTo(0.25, 0.01));
      expect(container.read(preferencesProvider).volume, 0.5);
    });

    test('fade ao pausar: o som desce até 0 e só então o motor para', () async {
      final c = fading();
      await c.read(preferencesProvider.notifier).setPauseFade(100);
      final ctl = c.read(playerProvider.notifier);
      await ctl.playList(abc, 0, context: 'Busca');
      engine.volumes.clear();
      await ctl.togglePlay();
      expect(c.read(playerProvider).status, PlaybackStatus.pausado);
      expect(engine.volumes.length, greaterThan(2), reason: 'desce aos poucos');
      expect(engine.volumes.last, 0);
      expect(engine.playing, isFalse);
      // Voltar a tocar sobe de novo.
      await ctl.togglePlay();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(engine.volume, 1.0);
    });

    test('fade na troca: a música nova começa do silêncio e sobe', () async {
      final c = fading();
      await c.read(preferencesProvider.notifier).setTrackFade(100);
      final ctl = c.read(playerProvider.notifier);
      engine.volumes.clear();
      await ctl.playList(abc, 0, context: 'Busca');
      expect(engine.volumes.first, 0);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(engine.volume, 1.0);
    });
  });
}
