import 'dart:async';

import 'package:bergastream/core/network/api_error.dart';
import 'package:bergastream/core/platform/app_platform.dart';
import 'package:bergastream/core/storage/key_value_store.dart';
import 'package:bergastream/data/local/database.dart';
import 'package:bergastream/data/models/search_result.dart';
import 'package:bergastream/data/repositories/playback_repository.dart';
import 'package:bergastream/data/repositories/radio_repository.dart';
import 'package:bergastream/features/auth/session.dart';
import 'package:bergastream/features/player/audio_engine.dart';
import 'package:bergastream/features/player/player_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../app_harness.dart';
import '../../fake_player.dart';

/// Rádio que pode segurar a resposta e falhar sob comando.
class _Radio implements RadioRepository {
  final requests = <RadioRequest>[];
  final batches = <List<SearchResult>>[];
  Completer<void>? gate;
  ApiException? fail;

  @override
  Future<List<SearchResult>> next(RadioRequest request) async {
    requests.add(request);
    if (gate case final g?) await g.future;
    if (fail case final f?) throw f;
    return batches.isEmpty ? const [] : batches.removeAt(0);
  }
}

List<SearchResult> songs(String prefix, int n) => [
  for (var i = 0; i < n; i++) song('$prefix$i'),
];

void main() {
  late FakeAudioEngine engine;
  late _Radio radio;
  late ProviderContainer container;

  PlayerController controller() => container.read(playerProvider.notifier);
  PlayerState state() => container.read(playerProvider);
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 20));

  setUp(() {
    engine = FakeAudioEngine();
    radio = _Radio();
    container = ProviderContainer(
      overrides: [
        audioEngineProvider.overrideWithValue(engine),
        playbackRepositoryProvider.overrideWithValue(FakePlaybackRepository()),
        radioRepositoryProvider.overrideWithValue(radio),
        playerTimingsProvider.overrideWithValue(
          const PlayerTimings(
            pollInterval: Duration.zero,
            rapidChangeDelay: Duration.zero,
            autoSkipDelay: Duration.zero,
            radioDelay: Duration(milliseconds: 50),
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

  test('toca na hora e só depois da espera pede a rádio', () async {
    radio.batches.add(songs('R', 10));
    await controller().startRadio(song('Semente'));
    expect(state().current!.track.title, 'Semente');
    expect(engine.playing, isTrue);
    expect(state().context, 'Rádio de Semente');
    expect(radio.requests, isEmpty, reason: 'ainda na espera');
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(radio.requests.single.seed.title, 'Semente');
    expect(state().upNext.map((i) => i.track.title), [
      for (var i = 0; i < 10; i++) 'R$i',
    ]);
  });

  test('vários toques seguidos: só a última música pede rádio', () async {
    radio.batches.add(songs('R', 10));
    await controller().startRadio(song('A'));
    await controller().startRadio(song('B'));
    await controller().startRadio(song('C'));
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(radio.requests.map((r) => r.seed.title), ['C']);
    expect(state().current!.track.title, 'C');
  });

  test('rádio velha que responde depois é descartada', () async {
    final first = Completer<void>();
    radio
      ..gate = first
      ..batches.addAll([songs('Velha', 10)]);
    await controller().startRadio(song('A'));
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(radio.requests, hasLength(1));
    radio.gate = null;
    // Tocar outra coisa (uma lista) encerra a rádio.
    await controller().playList([song('X')], 0, context: 'Busca');
    first.complete();
    await settle();
    expect(state().upNext, isEmpty);
    expect(controller().isRadio, isFalse);
  });

  test('recarrega quando faltam 5, sem repetir o que já tocou', () async {
    radio.batches.addAll([songs('R', 7), songs('S', 10)]);
    await controller().startRadio(song('Semente'));
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(state().upNext, hasLength(7));
    await controller().next(); // sobram 6
    expect(radio.requests, hasLength(1));
    await controller().next(); // sobram 5: pede mais
    await settle();
    expect(radio.requests, hasLength(2));
    final excluded = radio.requests.last.exclude.map((t) => t.title).toSet();
    expect(excluded, containsAll(['Semente', 'R0', 'R1', 'R6']));
    expect(state().upNext, hasLength(15));
  });

  test(
    'pular antes dos 30 s conta para o artista; ouvir vira semente',
    () async {
      radio.batches.addAll([songs('R', 7), songs('S', 1), songs('T', 10)]);
      await controller().startRadio(song('Semente'));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await controller().next(); // toca R0 (sobram 6)
      engine.emitPosition(const Duration(seconds: 40)); // R0 ouvida
      await settle();
      await controller().next(); // toca R1 (sobram 5): pede mais
      await settle();
      expect(radio.requests, hasLength(2));
      expect(radio.requests[1].recent.map((t) => t.title), ['R0']);
      expect(radio.requests[1].skipped, isEmpty);
      await controller().next(); // R1 pulada logo no começo; sobram 5 de novo
      await settle();
      final last = radio.requests.last;
      expect(radio.requests, hasLength(3));
      expect(last.skipped, {'Artista R1': 1});
      expect(last.recent.map((t) => t.title), ['R0']);
      expect(last.seed.title, 'Semente', reason: 'a âncora nunca muda');
    },
  );

  test('muitas rádios seguidas: mostra o aviso do servidor', () async {
    radio.fail = const ApiException(
      ApiErrorKind.muitasTentativas,
      statusCode: 429,
      detail: 'Muitas rádios seguidas. Espere um pouco.',
    );
    await controller().startRadio(song('A'));
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(state().message?.text, 'Muitas rádios seguidas. Espere um pouco.');
    expect(state().current!.track.title, 'A', reason: 'a música continua');
  });

  test(
    'pular para a última já pede mais, sem repetir o que estava no meio',
    () async {
      radio.batches.addAll([songs('R', 12), songs('S', 10)]);
      await controller().startRadio(song('Semente'));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(state().upNext, hasLength(12));
      // Toca direto a última da fila (as do meio nunca tocaram).
      await controller().jumpTo(state().upNext.last.uid);
      await settle();
      expect(radio.requests, hasLength(2), reason: 'já pede a próxima leva');
      final excluded = radio.requests.last.exclude.map((t) => t.title).toSet();
      expect(
        excluded,
        containsAll(['R0', 'R5', 'R10', 'R11']),
        reason: 'o que apareceu na fila não volta, mesmo sem ter tocado',
      );
    },
  );
}
