import 'package:bergastream/data/models/playlist_op.dart';
import 'package:bergastream/data/repositories/playlist_repository.dart';
import 'package:bergastream/features/auth/session.dart';
import 'package:bergastream/features/library/playlist_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../app_harness.dart';

void main() {
  const pendingText =
      'Alterações salvas no aparelho. Vão para o servidor quando ele voltar.';

  Future<(FakePlaylistRepository, ProviderContainer)> openRoadtrip(
    WidgetTester tester,
  ) async {
    final repo = FakePlaylistRepository();
    final container = await pumpBergastream(
      tester,
      initialLocation: '/biblioteca',
      playlists: repo,
      size: const Size(400, 1400),
    );
    await tester.tap(find.text('Roadtrip'));
    await settleDb(tester);
    expect(find.byType(PlaylistScreen), findsOneWidget);
    return (repo, container);
  }

  Future<void> rename(WidgetTester tester, String name) async {
    await tester.tap(find.byTooltip('Opções da playlist'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Renomear'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, name);
    await tester.tap(find.text('Salvar'));
    await settleDb(tester);
  }

  testWidgets('sem servidor: edita na hora e envia quando ele volta', (
    tester,
  ) async {
    final (repo, container) = await openRoadtrip(tester);
    container.read(sessionProvider.notifier).setServerAvailable(false);
    await settleDb(tester);

    await rename(tester, 'Celular');
    await tester.tap(find.byTooltip('Mais opções').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remover desta playlist'));
    await settleDb(tester);

    expect(find.text('Celular'), findsOneWidget);
    expect(find.text('Blinding Lights'), findsNothing);
    expect(find.text(pendingText), findsOneWidget);
    expect(repo.batches, isEmpty);

    container.read(sessionProvider.notifier).setServerAvailable(true);
    await settleDb(tester);
    await settleDb(tester);
    expect(repo.playlists.single.name, 'Celular');
    expect(repo.removed, ['tr0']);
    expect(find.text(pendingText), findsNothing);
    expect(find.text('Enviando alterações…'), findsNothing);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  testWidgets('conflito vira aviso na Biblioteca e a pessoa decide', (
    tester,
  ) async {
    final (repo, _) = await openRoadtrip(tester);
    // O servidor responde que o nome mudou em outro lugar.
    repo.opsHandler = (ops) => OpBatchResult(
      results: [
        for (final o in ops)
          OpResult(
            opId: o.opId,
            status: o.force ? OpStatus.applied : OpStatus.conflict,
            playlistId: 'p1',
            current: const {'name': 'Nome da web'},
          ),
      ],
    );
    await rename(tester, 'Celular');
    await settleDb(tester);
    expect(
      find.text(
        'Uma alteração de playlist precisa da sua decisão (Biblioteca)',
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('‹ Biblioteca'));
    await settleDb(tester);
    await tester.tap(
      find.text('1 alteração de playlist precisa da sua decisão'),
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('mudou em outro lugar para "Nome da web"'),
      findsOneWidget,
    );

    await tester.tap(find.text('Usar "Celular"'));
    await settleDb(tester);
    final forced = repo.batches.last.single;
    expect(
      (forced.type, forced.name, forced.force),
      (PlaylistOpType.rename, 'Celular', true),
    );
    expect(
      find.text('1 alteração de playlist precisa da sua decisão'),
      findsNothing,
    );
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });
}
