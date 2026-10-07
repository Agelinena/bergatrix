import 'dart:async';

import 'package:bergastream/core/platform/app_platform.dart';
import 'package:bergastream/core/storage/key_value_store.dart';
import 'package:bergastream/data/local/database.dart';
import 'package:bergastream/data/models/search_result.dart';
import 'package:bergastream/features/auth/session.dart';
import 'package:bergastream/data/repositories/playback_repository.dart';
import 'package:bergastream/features/player/audio_engine.dart';
import 'package:bergastream/features/player/play_queue.dart';
import 'package:bergastream/features/player/player_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:bergastream/features/playlists/last_played.dart';
import 'package:bergastream/features/playlists/playlist_shuffle.dart';
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
          const PlayerTimings(pollInterval: Duration.zero),
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
    engine.complete();
    await pumpEventQueue();
    expect(state().current!.track.title, 'X');
    engine.complete();
    await pumpEventQueue();
    expect(state().current!.track.title, 'B');
  });

  test('fim de tudo: para (repetir desligado)', () async {
    await controller().playList([song('A')], 0, context: 'Busca');
    engine.complete();
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
    engine.complete();
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
          const PlayerTimings(pollInterval: Duration.zero),
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
}
