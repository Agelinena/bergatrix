import 'package:bergastream/core/network/api_error.dart';
import 'package:bergastream/core/platform/app_platform.dart';
import 'package:bergastream/core/storage/key_value_store.dart';
import 'package:bergastream/data/local/database.dart';
import 'package:bergastream/data/models/search_result.dart';
import 'package:bergastream/data/repositories/lyrics_repository.dart';
import 'package:bergastream/features/auth/session.dart';
import 'package:bergastream/features/player/full_player.dart';
import 'package:bergastream/features/player/lyrics.dart';
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
}

void main() {
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
  }) async {
    final engine = FakeAudioEngine();
    await pumpBergastream(tester, engine: engine, size: const Size(400, 1800));
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

    engine.emitPosition(const Duration(seconds: 16));
    await tester.pumpAndSettle();
    // A atual vem primeiro; a que já passou sai do cartão.
    expect(find.text('Primeira linha da letra'), findsNothing);
    final current = tester.widget<Text>(find.text('Segunda linha da letra'));
    expect(current.style!.fontWeight, FontWeight.w800);
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
