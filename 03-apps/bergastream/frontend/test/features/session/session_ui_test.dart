import 'package:bergastream/data/models/playlist_models.dart';
import 'package:bergastream/data/repositories/session_repository.dart';
import 'package:bergastream/features/session/session_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../app_harness.dart';
import '../../helpers.dart';

const marina = Person(id: 'u-marina', username: 'marina', name: 'Marina');

void main() {
  testWidgets('criar sessão com "cada um pausa o seu"', (tester) async {
    tester.view.physicalSize = const Size(400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = FakeSessionRepository();
    await tester.pumpWidget(wrap(const SessionSheet(), sessions: repo));
    await tester.pumpAndSettle();

    expect(find.text(SessionTexts.title), findsOneWidget);
    await tester.tap(find.text(PauseMode.individual.label));
    await tester.pump();
    await tester.tap(find.text(SessionTexts.create));
    await tester.pumpAndSettle();

    expect(repo.calls, contains('create:individual'));
    // Dentro da sessão: pessoas e encerrar (quem criou).
    expect(find.text('Pessoas'), findsOneWidget);
    expect(find.text('Demo (você)'), findsOneWidget);
    expect(find.text(SessionTexts.end), findsOneWidget);
  });

  testWidgets('convidar: escolhe pessoas do servidor', (tester) async {
    tester.view.physicalSize = const Size(400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = FakeSessionRepository();
    await tester.pumpWidget(wrap(const SessionSheet(), sessions: repo));
    await tester.pumpAndSettle();
    await tester.tap(find.text(SessionTexts.create));
    await tester.pumpAndSettle();

    await tester.tap(find.text(SessionTexts.invite));
    await tester.pumpAndSettle();
    // Você não aparece na lista.
    expect(find.widgetWithText(CheckboxListTile, 'Demo'), findsNothing);
    await tester.tap(find.text('Ana'));
    await tester.pump();
    await tester.tap(find.text(SessionTexts.invite).last);
    await tester.pumpAndSettle();
    expect(repo.calls, contains('invite:u2'));
  });

  testWidgets('convite chega: "Entrar" entra na sessão', (tester) async {
    final repo = FakeSessionRepository(
      invites: [const SessionInvite(sessionId: 's9', name: '', owner: marina)],
    );
    await pumpBergastream(tester, sessions: repo);
    await tester.pumpAndSettle();

    expect(find.text('Marina te chamou para ouvir junto'), findsOneWidget);
    await tester.tap(find.text('Entrar'));
    await tester.pumpAndSettle();
    expect(repo.calls, contains('join:s9'));
  });

  testWidgets('convite: "Agora não" recusa', (tester) async {
    final repo = FakeSessionRepository(
      invites: [const SessionInvite(sessionId: 's9', name: '', owner: marina)],
    );
    await pumpBergastream(tester, sessions: repo);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Agora não'));
    await tester.pumpAndSettle();
    expect(repo.calls, contains('decline:s9'));
    expect(find.text('Marina te chamou para ouvir junto'), findsNothing);
  });
}
