import 'package:bergastream/core/network/api_error.dart';
import 'package:bergastream/core/platform/app_platform.dart';
import 'package:bergastream/core/storage/key_value_store.dart';
import 'package:bergastream/data/local/database.dart';
import 'package:bergastream/data/models/search_result.dart';
import 'package:bergastream/data/repositories/lyrics_repository.dart';
import 'package:bergastream/features/auth/session.dart';
import 'package:bergastream/features/player/full_player.dart';
import 'package:bergastream/features/player/lyrics.dart';
import 'package:bergastream/features/player/lyrics_marker.dart';
import 'package:bergastream/features/player/player_controller.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../app_harness.dart';
import '../../fake_player.dart';

/// Conta as chamadas e pode simular servidor fora.
class CountingLyrics implements LyricsRepository {
  int calls = 0;
  bool offline = false;

  @override
  Future<Lyrics> lyrics(SearchResult track) async {
    calls++;
    if (offline) throw const ApiException(ApiErrorKind.semConexao);
    return FakeLyricsRepository.sample;
  }

  @override
  Future<Lyrics> edit(
    String trackId, {
    int? offsetMs,
    String? lrc,
    String? plain,
  }) async => FakeLyricsRepository.sample;

  @override
  Future<Lyrics> reset(String trackId) async => FakeLyricsRepository.sample;
}

void main() {
  test('prévia do ajuste: as linhas andam juntas, sem tempo negativo', () {
    const lines = FakeLyricsRepository.sample;
    final later = lines.shifted(1250);
    expect(later.synced.map((l) => l.time.inMilliseconds), [
      6250,
      16250,
      26250,
    ]);
    expect(later.offsetMs, 1250);
    expect(lines.shifted(-6000).synced.first.time, Duration.zero);
    expect(identical(lines.shifted(0), lines), isTrue);
  });

  test('linha atual: a última que já começou', () {
    const lines = FakeLyricsRepository.sample;
    expect(currentLineIndex(lines.synced, Duration.zero), -1);
    expect(currentLineIndex(lines.synced, const Duration(seconds: 5)), 0);
    // Acende um pouco antes da voz (250 ms).
    expect(
      currentLineIndex(lines.synced, const Duration(milliseconds: 14800)),
      1,
    );
    expect(currentLineIndex(lines.synced, const Duration(minutes: 3)), 2);
  });

  Future<FakeAudioEngine> playAndOpen(
    WidgetTester tester, {
    String title = 'Bohemian Rhapsody',
    FakeLyricsRepository? lyrics,
  }) async {
    final engine = FakeAudioEngine();
    await pumpBergastream(
      tester,
      engine: engine,
      size: const Size(400, 1800),
      lyrics: lyrics,
    );
    await tester.tap(find.text('Buscar').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'queen');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Queen · A Night at the Opera'));
    await settleDb(tester);
    expect(find.byType(FullPlayer), findsOneWidget);
    return engine;
  }

  testWidgets('player grande: cartão "Letra" acompanha a música', (
    tester,
  ) async {
    final engine = await playAndOpen(tester);
    expect(find.text(LyricsCard.title), findsOneWidget);
    expect(find.text('Primeira linha da letra'), findsOneWidget);

    engine.emitPosition(const Duration(seconds: 26));
    await tester.pumpAndSettle();
    // A anterior fica (apagada); as de antes dela saem do cartão.
    expect(find.text('Primeira linha da letra'), findsNothing);
    expect(find.text('Segunda linha da letra'), findsOneWidget);
    final current = tester.widget<Text>(find.text('Terceira linha da letra'));
    final previous = tester.widget<Text>(find.text('Segunda linha da letra'));
    expect(current.style!.fontSize, 22);
    expect(current.style!.color!.a, greaterThan(previous.style!.color!.a));
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  testWidgets('letra em tela cheia: tocar numa linha pula para ela', (
    tester,
  ) async {
    final engine = await playAndOpen(tester);
    await tester.tap(find.text(LyricsCard.title));
    await tester.pumpAndSettle();
    expect(find.byType(LyricsView), findsOneWidget);
    expect(find.text('Terceira linha da letra'), findsOneWidget);
    await tester.tap(find.text('Terceira linha da letra'));
    await tester.pumpAndSettle();
    expect(engine.log.last, 'seek 25');
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  testWidgets('ajustar letra: a prévia anda na hora e salva para todos', (
    tester,
  ) async {
    final lyrics = FakeLyricsRepository();
    await playAndOpen(tester, lyrics: lyrics);
    await tester.tap(find.text(LyricsCard.title));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ajustar letra'));
    await tester.pumpAndSettle();
    expect(find.text('Sincronia: sem ajuste'), findsOneWidget);
    await tester.tap(find.text('+1 s'));
    await tester.tap(find.text('+0,1 s'));
    await tester.pumpAndSettle();
    expect(find.text('Sincronia: +1,1 s'), findsOneWidget);

    await tester.tap(find.text('Salvar para todos'));
    await tester.pumpAndSettle();
    expect(lyrics.edits.single.offsetMs, 1100);
    expect(find.text('Sincronia salva'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  testWidgets('marcar linha a linha: cada linha no tempo em que é cantada', (
    tester,
  ) async {
    final lyrics = FakeLyricsRepository();
    final engine = await playAndOpen(tester, lyrics: lyrics);
    await tester.tap(find.text(LyricsCard.title));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ajustar letra'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Marcar linha a linha'));
    await tester.pumpAndSettle();
    expect(find.text('Marcar a letra'), findsOneWidget);

    // A primeira linha começa aos 7,15 s (marca com o tempo de reação).
    engine.emitPosition(const Duration(milliseconds: 7150));
    await tester.pump();
    await tester.tap(find.text('Marcar'));
    await tester.pumpAndSettle();
    expect(find.text('00:07.00'), findsOneWidget);
    // Agora a segunda está escolhida: ajuste fino de +0,1 s.
    await tester.tap(find.text('+0,1 s'));
    await tester.pumpAndSettle();
    expect(find.text('00:15.10'), findsOneWidget);

    await tester.tap(find.text('Salvar para todos'));
    await tester.pumpAndSettle();
    final saved = lyrics.edits.single;
    expect(saved.offsetMs, 0);
    expect(
      saved.lrc,
      '[00:07.00] Primeira linha da letra\n'
      '[00:15.10] Segunda linha da letra\n'
      '[00:25.00] Terceira linha da letra',
    );
    expect(find.text('Marcar a letra'), findsNothing);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  test('LRC das linhas marcadas sai em ordem de tempo', () {
    final lines = [
      MarkLine('b', const Duration(seconds: 70, milliseconds: 500)),
      MarkLine('a', const Duration(seconds: 3)),
    ];
    expect(toLrc(lines), '[00:03.00] a\n[01:10.50] b');
    expect(
      markLinesFrom(const Lyrics(found: true, plain: 'um\n\ndois')).length,
      2,
      reason: 'letra simples: uma linha por verso, sem tempo',
    );
  });

  testWidgets('editar o texto da letra', (tester) async {
    final lyrics = FakeLyricsRepository();
    await playAndOpen(tester, lyrics: lyrics);
    await tester.tap(find.text(LyricsCard.title));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ajustar letra'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Editar o texto'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField).last,
      '[00:02.00] Linha corrigida',
    );
    await tester.tap(find.text('Salvar para todos'));
    await tester.pumpAndSettle();
    expect(lyrics.edits.single.lrc, '[00:02.00] Linha corrigida');
    expect(find.text('Letra salva'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  testWidgets('letra em tela cheia fecha quando a música muda', (tester) async {
    await playAndOpen(tester);
    await tester.tap(find.text(LyricsCard.title));
    await tester.pumpAndSettle();
    expect(find.byType(LyricsPage), findsOneWidget);
    // Outra música começa: volta para o player.
    final container = ProviderScope.containerOf(
      tester.element(find.byType(LyricsPage)),
    );
    await container
        .read(playerProvider.notifier)
        .playList([song('Outra')], 0, context: 'Teste');
    await tester.pumpAndSettle();
    expect(find.byType(LyricsPage), findsNothing);
    expect(find.byType(FullPlayer), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  testWidgets('navegador: botão "Letra" abre o painel no lugar da fila', (
    tester,
  ) async {
    await pumpBergastream(
      tester,
      platform: const AppPlatform.web(),
      size: const Size(1400, 900),
    );
    await tester.tap(find.text('Buscar'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'queen');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bohemian Rhapsody'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Fila'));
    await tester.pumpAndSettle();
    expect(find.text('Sua fila'), findsOneWidget);
    await tester.tap(find.byTooltip('Letra'));
    await tester.pumpAndSettle();
    expect(find.byType(LyricsView), findsOneWidget);
    expect(find.text('Sua fila'), findsNothing);
    expect(find.text('Primeira linha da letra'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  test('letra fica no aparelho: depois funciona sem servidor', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = CountingLyrics();
    final container = ProviderContainer(
      overrides: [
        appPlatformProvider.overrideWithValue(const AppPlatform.app()),
        keyValueStoreProvider.overrideWithValue(MemoryKeyValueStore()),
        initialSessionProvider.overrideWithValue(loggedIn),
        localDatabaseProvider.overrideWithValue(db),
        lyricsRepositoryProvider.overrideWithValue(repo),
      ],
    );
    addTearDown(container.dispose);
    const track = SearchResult(
      provider: 'spotify',
      externalId: 'x1',
      title: 'Wind Of Change',
      artist: 'Scorpions',
    );
    Future<Lyrics> read() async {
      final sub = container.listen(
        lyricsProvider(const LyricsRequest(track)),
        (_, _) {},
      );
      final value = await container.read(
        lyricsProvider(const LyricsRequest(track)).future,
      );
      sub.close();
      return value;
    }

    expect((await read()).synced, hasLength(3));
    container.read(sessionProvider.notifier).setServerAvailable(false);
    repo.offline = true;
    container.invalidate(lyricsProvider);
    final offline = await read();
    expect(offline.synced, hasLength(3));
    expect(repo.calls, 1); // a segunda veio do aparelho
  });
}
