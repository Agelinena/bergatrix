import 'package:bergastream/core/platform/app_platform.dart';
import 'package:bergastream/data/repositories/radio_repository.dart';
import 'package:bergastream/features/player/full_player.dart';
import 'package:bergastream/features/player/in_playlists.dart';
import 'package:bergastream/features/player/lyrics.dart';
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
    // Tocar uma música da busca começa a rádio dela.
    expect(find.text('Rádio de Bohemian Rhapsody'), findsOneWidget);

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
      radio: FakeRadioRepository([
        [song('Parecida 1'), song('Parecida 2')],
      ]),
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
    expect(find.text('A seguir na rádio'), findsOneWidget);
    expect(find.text('Parecida 1'), findsOneWidget);
  });

  testWidgets('tela larga: player dividido, letra ou fila à direita', (
    tester,
  ) async {
    await pumpBergastream(
      tester,
      platform: const AppPlatform.web(),
      size: const Size(1400, 900),
      radio: FakeRadioRepository([
        [song('Parecida 1')],
      ]),
    );
    await tester.tap(find.text('Buscar'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'queen');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bohemian Rhapsody'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Abrir player'));
    await tester.pumpAndSettle();

    expect(find.byType(FullPlayer), findsOneWidget);
    expect(find.byType(LyricsView), findsOneWidget, reason: 'letra à direita');
    expect(find.byType(QueuePanel), findsNothing);
    // O botão Fila (ou o chip) troca o painel da direita.
    await tester.tap(find.byTooltip('Fila').last);
    await tester.pumpAndSettle();
    expect(find.byType(QueuePanel), findsOneWidget);
    expect(find.text('Parecida 1'), findsWidgets);
  });

  testWidgets('player mostra se a música está numa playlist sua', (
    tester,
  ) async {
    await pumpBergastream(
      tester,
      size: const Size(400, 1000),
      inPlaylists: FakeInPlaylistsLookup({
        'Bohemian Rhapsody': [(id: 'p1', name: 'Rock in Metal')],
      }),
    );
    await searchAndPlay(tester, 'Bohemian Rhapsody');
    await tester.tap(find.text('Queen · A Night at the Opera'));
    await tester.pumpAndSettle();
    expect(find.text('Na sua playlist Rock in Metal'), findsOneWidget);
  });
}
