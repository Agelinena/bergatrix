import 'package:bergastream/core/platform/app_platform.dart';
import 'package:bergastream/features/player/full_player.dart';
import 'package:bergastream/features/player/player_bar.dart';
import 'package:bergastream/features/player/player_controller.dart';
import 'package:bergastream/features/player/queue_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../app_harness.dart';
import '../../fake_player.dart';

void main() {
  Future<void> searchAndPlay(WidgetTester tester, String title) async {
    await tester.tap(find.text('Buscar').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'queen');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
  }

  testWidgets('sem faixa carregada não há mini player', (tester) async {
    await pumpBergastream(tester);
    expect(find.byIcon(Icons.pause), findsNothing);
    expect(find.byIcon(Icons.play_arrow), findsNothing);
  });

  testWidgets('tocar da busca mostra o mini player e o título em verde', (
    tester,
  ) async {
    final engine = FakeAudioEngine();
    await pumpBergastream(tester, engine: engine, size: const Size(360, 900));
    await searchAndPlay(tester, 'Bohemian Rhapsody');

    expect(engine.playing, isTrue);
    expect(find.byIcon(Icons.pause), findsOneWidget);
    // Título na linha (verde) e no mini player.
    expect(find.text('Bohemian Rhapsody'), findsNWidgets(2));
  });

  testWidgets('mini player abre o player grande; botões mudam o estado', (
    tester,
  ) async {
    final container = await pumpBergastream(
      tester,
      size: const Size(400, 1000),
    );
    await searchAndPlay(tester, 'Bohemian Rhapsody');

    await tester.tap(find.text('Queen · A Night at the Opera'));
    await tester.pumpAndSettle();
    expect(find.byType(FullPlayer), findsOneWidget);
    expect(find.text('Tocando de Busca'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.pause).last);
    await tester.pump();
    expect(container.read(playerProvider).status, PlaybackStatus.pausado);

    await tester.tap(find.byTooltip('Aleatório'));
    await tester.pump();
    expect(container.read(playerProvider).shuffle, isTrue);

    await tester.tap(find.byTooltip('Fila'));
    await tester.pumpAndSettle();
    expect(find.byType(QueuePanel), findsOneWidget);
    expect(find.text('Sua fila'), findsOneWidget);

    await tester.tap(find.byTooltip('Fechar'));
    await tester.pumpAndSettle();
    expect(find.byType(FullPlayer), findsNothing);
  });

  testWidgets('"Adicionar à fila" pelo ⋮ mostra o aviso e entra na fila', (
    tester,
  ) async {
    final container = await pumpBergastream(
      tester,
      size: const Size(400, 1000),
    );
    await searchAndPlay(tester, 'Bohemian Rhapsody');

    await tester.tap(find.byTooltip('Mais opções').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Adicionar à fila'));
    await tester.pump();
    expect(find.text('Na fila: toca depois da atual'), findsOneWidget);
    expect(container.read(playerProvider).manual, hasLength(1));
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  });

  testWidgets('erro ao tocar aparece como aviso', (tester) async {
    await pumpBergastream(
      tester,
      playback: FakePlaybackRepository(failPrepare: true),
      size: const Size(400, 1000),
    );
    await searchAndPlay(tester, 'Bohemian Rhapsody');
    expect(find.text(PlayerController.notPlayable), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  });

  testWidgets('navegador: barra do player e painel da fila', (tester) async {
    await pumpBergastream(
      tester,
      platform: const AppPlatform.web(),
      size: const Size(1280, 900),
    );
    expect(find.byTooltip('Fila'), findsNothing);
    await tester.tap(find.text('Buscar'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'queen');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bohemian Rhapsody'));
    await tester.pumpAndSettle();

    expect(find.byType(PlayerBar), findsOneWidget);
    await tester.tap(find.byTooltip('Fila'));
    await tester.pumpAndSettle();
    expect(find.byType(QueuePanel), findsOneWidget);
    expect(find.text('A seguir'), findsOneWidget);
  });
}
