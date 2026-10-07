import 'dart:io';

import 'package:bergastream/core/widgets/download_state_icon.dart';
import 'package:bergastream/data/local/database.dart';
import 'package:bergastream/data/repositories/playlist_repository.dart';
import 'package:bergastream/features/auth/session.dart';
import 'package:bergastream/features/downloads/file_fetcher.dart';
import 'package:bergastream/features/player/player_controller.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../app_harness.dart';
import '../../fake_player.dart';

/// Download que escreve um arquivo pequeno de verdade.
class _QuickFetcher implements FileFetcher {
  @override
  Future<FetchResult> fetch(
    Uri url,
    String path, {
    String? label,
    void Function(double progress)? onProgress,
  }) async {
    await File(path).writeAsBytes([1, 2, 3]);
    return const FetchResult(bytes: 3, expectedBytes: 3, format: 'mp3');
  }
}

void main() {
  late AppDatabase db;
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('offline'));
  tearDown(() => dir.deleteSync(recursive: true));

  /// O banco precisa nascer dentro do teste (zona de relógio falso do
  /// testWidgets); criado no setUp, as consultas ficariam esperando a zona
  /// real e a tela ficaria em "Carregando…".
  void openDb() => db = AppDatabase(NativeDatabase.memory());

  /// Playlist p1 baixada: a primeira faixa com arquivo de verdade.
  /// O banco em memória é síncrono: roda no relógio falso dos testes.
  Future<void> seedDownloaded(WidgetTester tester) async {
    openDb();
    final detail = await FakePlaylistRepository().detail('p1');
    await db.savePlaylist(detail);
    // Download pausado: só a primeira faixa está no aparelho.
    await db.setPaused('p1', true);
    final file = File('${dir.path}/tr0.mp3')..writeAsBytesSync([1]);
    await db.updateTrack(
      'tr0',
      LocalTracksCompanion(
        audioPath: Value(file.path),
        downloadState: const Value(DownloadState.baixada),
        sizeBytes: const Value(4000000),
      ),
    );
  }

  testWidgets('baixar a playlist: confirma, baixa e mostra "Baixada"', (
    tester,
  ) async {
    openDb();
    await pumpBergastream(
      tester,
      db: db,
      fetcher: _QuickFetcher(),
      initialLocation: '/biblioteca/playlist/p1',
      size: const Size(400, 1400),
    );
    // Downloads vão para a pasta temporária do teste.
    await tester.tap(find.text('Baixar no aparelho'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Baixar 5 músicas, cerca de'), findsOneWidget);
    await tester.tap(find.text('Baixar'));
    // O download escreve arquivos de verdade: deixa o tempo real correr em
    // pedaços e processa o resto a cada quadro.
    // Até aparecer "Baixada" (limite de ~10 s de tempo real).
    for (var i = 0; i < 500 && find.text('Baixada').evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pumpAndSettle();
    expect(find.text('Baixada'), findsOneWidget);
    expect(find.byIcon(Icons.download_done), findsWidgets);
  });

  testWidgets(
    'sem servidor: biblioteca mostra a baixada e toca o arquivo local',
    (tester) async {
      await seedDownloaded(tester);
      final engine = FakeAudioEngine();
      final container = await pumpBergastream(
        tester,
        db: db,
        engine: engine,
        initialLocation: '/biblioteca',
        size: const Size(400, 1400),
      );
      container.read(sessionProvider.notifier).setServerAvailable(false);
      await settleDb(tester);
      expect(
        find.text('Servidor indisponível. Mostrando suas músicas baixadas.'),
        findsOneWidget,
      );
      // A lista vem da cópia guardada quando havia servidor; a baixada
      // aparece com o ícone.
      expect(find.text('Roadtrip'), findsOneWidget);
      expect(find.byIcon(Icons.download_done), findsWidgets);

      await tester.tap(find.text('Roadtrip'));
      await settleDb(tester);
      // Lida do banco local, com quem adicionou.
      expect(find.text('Dua Lipa · por Ana'), findsOneWidget);
      expect(find.text('Baixar no aparelho'), findsNothing);

      await tester.tap(find.text('Blinding Lights'));
      await settleDb(tester);
      expect(engine.files.single, endsWith('tr0.mp3'));
      expect(engine.urls, isEmpty);

      // Faixa não baixada: aviso.
      await tester.tap(find.text('Levitating'));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.text(PlayerController.notDownloaded), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('sem login: busca local nas músicas baixadas', (tester) async {
    await seedDownloaded(tester);
    await pumpBergastream(
      tester,
      db: db,
      session: noServer.copyWith(localMode: true),
      initialLocation: '/buscar',
      size: const Size(400, 1400),
    );
    await tester.enterText(find.byType(TextField), 'blinding');
    await settleDb(tester);
    expect(find.text('Músicas baixadas'), findsOneWidget);
    expect(find.text('Blinding Lights'), findsOneWidget);
  });

  testWidgets('Ajustes: cartão Offline com números reais e Gerenciar', (
    tester,
  ) async {
    await seedDownloaded(tester);
    await pumpBergastream(
      tester,
      db: db,
      initialLocation: '/ajustes',
      size: const Size(400, 1400),
    );
    expect(
      find.textContaining('Músicas baixadas no aparelho: 1 (4 MB)'),
      findsOneWidget,
    );
    await tester.tap(find.text('Gerenciar downloads'));
    await settleDb(tester);
    expect(find.text('Downloads'), findsOneWidget);
    expect(find.text('1 de 5 músicas · 4 MB'), findsOneWidget);
  });
}
