import 'package:bergastream/app/routes.dart';
import 'package:bergastream/data/models/search_result.dart';
import 'package:bergastream/data/repositories/failures_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../app_harness.dart';

void main() {
  FakeFailuresRepository repo() =>
      FakeFailuresRepository([
          const DownloadFailure(
            trackId: 't1',
            title: 'Música Rara',
            artist: 'Banda',
            durationSeconds: 200,
            error: 'Não baixou do Deezer nem do YouTube',
            attempts: 3,
            playlists: 2,
          ),
        ])
        ..found = const [
          SearchResult(
            provider: 'ytmusic',
            externalId: 'vid1',
            title: 'Música Rara (Ao vivo)',
            artist: 'Banda',
            durationSeconds: 201,
          ),
        ];

  Future<void> open(WidgetTester tester, FakeFailuresRepository failures) =>
      pumpBergastream(
        tester,
        size: const Size(420, 1200),
        initialLocation: AppRoutes.adminFailures,
        failures: failures,
      );

  testWidgets('lista com o erro, as tentativas e as playlists', (tester) async {
    await open(tester, repo());
    expect(find.text('Música Rara'), findsOneWidget);
    expect(find.text('Não baixou do Deezer nem do YouTube'), findsOneWidget);
    expect(find.text('em 2 playlists · 3 tentativas'), findsOneWidget);
  });

  testWidgets('procurar manualmente e escolher a versão', (tester) async {
    final failures = repo();
    await open(tester, failures);
    await tester.tap(find.text('Música Rara'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Procurar manualmente'));
    await tester.pumpAndSettle();
    expect(failures.queries, ['Banda Música Rara']);
    expect(find.text('Música Rara (Ao vivo)'), findsOneWidget);
    await tester.tap(find.text('Música Rara (Ao vivo)'));
    await tester.pumpAndSettle();
    expect(failures.chosen, [('t1', 'vid1')]);
    expect(find.text('Baixando a versão escolhida'), findsOneWidget);
  });

  testWidgets('tentar de novo e ignorar', (tester) async {
    final failures = repo();
    await open(tester, failures);
    await tester.tap(find.text('Música Rara'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tentar de novo'));
    await tester.pumpAndSettle();
    expect(failures.retried, ['t1']);

    await tester.tap(find.text('Música Rara'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ignorar'));
    await tester.pumpAndSettle();
    expect(find.text('Nenhuma música com erro. Tudo baixado!'), findsOneWidget);
    await tester.tap(find.text('Ignoradas'));
    await tester.pumpAndSettle();
    expect(find.text('Música Rara'), findsOneWidget);
  });
}
