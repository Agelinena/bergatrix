import 'package:bergastream/features/settings/preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../app_harness.dart';

void main() {
  Future<void> openSettings(WidgetTester tester) async {
    await tester.tap(find.text('Ajustes').last);
    await tester.pumpAndSettle();
  }

  testWidgets('Aparência: escolher claro/escuro muda o tema do app', (
    tester,
  ) async {
    final container = await pumpBergastream(
      tester,
      size: const Size(400, 2000),
    );
    await openSettings(tester);
    expect(find.text('Segue o tema do aparelho'), findsOneWidget);

    await tester.tap(find.text('Escuro'));
    await tester.pumpAndSettle();
    expect(container.read(preferencesProvider).theme, AppTheme.escuro);
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.dark,
    );
    expect(find.text('Sempre escuro'), findsOneWidget);

    await tester.tap(find.text('Claro'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.light,
    );
  });

  testWidgets('No servidor: músicas, espaço, disco e fila do Deemix', (
    tester,
  ) async {
    await pumpBergastream(tester, size: const Size(400, 2400));
    await openSettings(tester);
    expect(find.text('No servidor'), findsOneWidget);
    expect(find.text('1200 · 9,7 GB'), findsOneWidget);
    expect(find.text('900 · 7,5 GB'), findsOneWidget);
    expect(find.text('1 baixando · 3 na fila'), findsOneWidget);
    expect(find.text('1 baixando · 2 na fila'), findsOneWidget);
    expect(
      find.text('Bohemian Rhapsody — Queen · baixando 40%'),
      findsOneWidget,
    );
    expect(find.text('Levitating — Dua Lipa · na fila'), findsOneWidget);
  });

  testWidgets('sem servidor o painel não aparece', (tester) async {
    await pumpBergastream(tester, session: noServer);
    await tester.tap(find.text('Continuar sem entrar'));
    await tester.pumpAndSettle();
    await openSettings(tester);
    expect(find.text('No servidor'), findsNothing);
    expect(find.text('Aparência'), findsOneWidget);
  });
}
