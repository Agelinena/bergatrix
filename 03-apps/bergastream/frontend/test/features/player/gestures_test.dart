import 'package:bergastream/features/library/library_providers.dart';
import 'package:bergastream/features/player/mini_player.dart';
import 'package:bergastream/features/player/player_controller.dart';
import 'package:bergastream/features/playlists/playlist_shuffle.dart';
import 'package:bergastream/data/repositories/playlist_repository.dart';
import 'package:bergastream/data/repositories/search_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../app_harness.dart';

void main() {
  Future<void> search(WidgetTester tester, String text) async {
    await tester.tap(find.text('Buscar').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), text);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'mini player: arrastar para a esquerda pula, para a direita volta',
    (tester) async {
      final container = await pumpBergastream(
        tester,
        size: const Size(400, 1400),
      );
      final tracks = [
        for (var i = 0; i < 3; i++)
          FakeSearchRepository.trackOf(i, SearchSource.spotify),
      ];
      await container
          .read(playerProvider.notifier)
          .playList(tracks, 0, context: 'Teste');
      await tester.pumpAndSettle();
      final first = container.read(playerProvider).current!.track.title;
      expect(first, tracks[0].title);

      await tester.drag(find.byType(MiniPlayer), const Offset(-150, 0));
      await tester.pumpAndSettle();
      final second = container.read(playerProvider).current!.track.title;
      expect(second, isNot(first));

      await tester.drag(find.byType(MiniPlayer), const Offset(150, 0));
      await tester.pumpAndSettle();
      expect(container.read(playerProvider).current!.track.title, first);

      // Arraste curto não troca.
      await tester.drag(find.byType(MiniPlayer), const Offset(-30, 0));
      await tester.pumpAndSettle();
      expect(container.read(playerProvider).current!.track.title, first);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('arraste curto na linha não põe na fila', (tester) async {
    final container = await pumpBergastream(
      tester,
      size: const Size(400, 1400),
    );
    await search(tester, 'queen');
    await tester.drag(find.text('Bohemian Rhapsody'), const Offset(-60, 0));
    await tester.pumpAndSettle();
    expect(container.read(playerProvider).current, isNull);
    expect(find.text('Na fila: toca depois da atual'), findsNothing);
  });

  testWidgets('"x" na busca apaga o texto; "x" no histórico apaga o termo', (
    tester,
  ) async {
    await pumpBergastream(tester, size: const Size(400, 1400));
    await search(tester, 'queen');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.text('Bohemian Rhapsody'), findsOneWidget);

    await tester.tap(find.byTooltip('Limpar'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'queen'), findsNothing);
    expect(find.text('Buscas recentes'), findsOneWidget);
    expect(find.byTooltip('Limpar'), findsNothing);

    await tester.tap(find.byTooltip('Apagar "queen" das buscas recentes'));
    await tester.pumpAndSettle();
    expect(find.text('Buscas recentes'), findsNothing);
  });

  testWidgets(
    'playlist com aleatório: busca filtrada ainda toca a playlist toda',
    (tester) async {
      final repo = FakePlaylistRepository();
      final container = await pumpBergastream(
        tester,
        initialLocation: '/biblioteca',
        playlists: repo,
        size: const Size(400, 1400),
      );
      await tester.tap(find.text('Roadtrip'));
      await settleDb(tester);
      await tester.tap(find.text('Aleatório'));
      await tester.pumpAndSettle();
      expect(container.read(playlistShuffleProvider('p1')), isTrue);

      // Busca mostra uma só música.
      await tester.enterText(find.byType(TextField), 'nirvana');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Smells Like Teen Spirit'));
      await tester.pumpAndSettle();
      final player = container.read(playerProvider);
      expect(player.current!.track.title, 'Smells Like Teen Spirit');
      expect(player.shuffle, isTrue);
      expect(player.upNext, hasLength(4)); // as outras 4 da playlist
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('o aleatório da playlist fica guardado ao sair e voltar', (
    tester,
  ) async {
    final container = await pumpBergastream(
      tester,
      initialLocation: '/biblioteca',
      playlists: FakePlaylistRepository(),
      size: const Size(400, 1400),
    );
    await tester.tap(find.text('Roadtrip'));
    await settleDb(tester);
    await tester.tap(find.text('Aleatório'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('‹ Biblioteca'));
    await settleDb(tester);
    container.invalidate(playlistShuffleProvider('p1'));
    container.invalidate(playlistSortProvider('p1'));
    await tester.tap(find.text('Roadtrip'));
    await settleDb(tester);
    expect(container.read(playlistShuffleProvider('p1')), isTrue);
  });
}
