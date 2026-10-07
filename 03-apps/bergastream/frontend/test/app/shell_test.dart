import 'package:bergastream/app/app_frame.dart';
import 'package:bergastream/app/app_shell.dart';
import 'package:bergastream/app/desktop_shell.dart';
import 'package:bergastream/core/platform/app_platform.dart';
import 'package:bergastream/features/player/mini_player.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../app_harness.dart';

void main() {
  Future<void> pumpApp(
    WidgetTester tester, {
    Size size = const Size(360, 800),
  }) async {
    await pumpBergastream(tester, size: size);
  }

  Future<void> goTo(WidgetTester tester, String tab) async {
    await tester.tap(find.text(tab).last);
    await tester.pumpAndSettle();
  }

  testWidgets('abre no Início com as 4 abas e o mini player', (tester) async {
    await pumpApp(tester);
    expect(find.text('Seu som'), findsOneWidget);
    for (final tab in ['Início', 'Buscar', 'Biblioteca', 'Ajustes']) {
      expect(find.text(tab), findsWidgets);
    }
    expect(find.byType(MiniPlayer), findsOneWidget);
    // Sem faixa carregada o mini player fica vazio.
    expect(find.byIcon(Icons.play_arrow), findsNothing);
  });

  testWidgets('troca de abas mostra cada tela', (tester) async {
    await pumpApp(tester);

    await goTo(tester, 'Buscar');
    expect(find.text('Músicas, artistas, álbuns ou link'), findsOneWidget);

    await goTo(tester, 'Biblioteca');
    expect(find.text('Roadtrip'), findsOneWidget);
    expect(find.text('Nova playlist'), findsOneWidget);

    await goTo(tester, 'Ajustes');
    expect(find.text('Qualidade de streaming'), findsOneWidget);

    await goTo(tester, 'Início');
    expect(find.text('Seu som'), findsOneWidget);
  });

  testWidgets('trocar de aba preserva o texto da busca', (tester) async {
    await pumpApp(tester);
    await goTo(tester, 'Buscar');
    await tester.enterText(find.byType(TextField), 'queen');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('Bohemian Rhapsody'), findsOneWidget);

    await goTo(tester, 'Início');
    await goTo(tester, 'Buscar');
    expect(find.text('queen'), findsOneWidget);
    expect(find.text('Bohemian Rhapsody'), findsOneWidget);
  });

  testWidgets('trocar de aba preserva a rolagem', (tester) async {
    await pumpApp(tester);
    final list = find.byType(Scrollable).first;
    await tester.drag(list, const Offset(0, -300));
    await tester.pumpAndSettle();
    final before = tester.state<ScrollableState>(list).position.pixels;
    expect(before, greaterThan(0));

    await goTo(tester, 'Biblioteca');
    await goTo(tester, 'Início');
    final after = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position
        .pixels;
    expect(after, before);
  });

  testWidgets('em 360 px o app ocupa a largura toda', (tester) async {
    await pumpApp(tester);
    expect(tester.getSize(find.byKey(AppFrame.contentKey)).width, 360);
    expect(find.byType(ClipRRect), findsNothing);
  });

  testWidgets('em 1200 px o app fica numa coluna de 430 px centralizada', (
    tester,
  ) async {
    await pumpApp(tester, size: const Size(1200, 900));
    final content = find.byKey(AppFrame.contentKey);
    expect(tester.getSize(content).width, 430);
    expect(tester.getCenter(content).dx, 600);
    // Nada fora da coluna: a barra de navegação também tem 430 px.
    expect(tester.getSize(find.byType(MobileShell)).width, 430);
  });

  testWidgets('no desktop o campo tem a mesma altura do celular (42)', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await pumpApp(tester);
    await goTo(tester, 'Buscar');
    expect(tester.getSize(find.byType(TextField)).height, 42);
    debugDefaultTargetPlatformOverride = null;
  });

  group('Windows/Linux', () {
    testWidgets('janela larga: layout de navegador com regras do app', (
      tester,
    ) async {
      await pumpBergastream(
        tester,
        platform: const AppPlatform.desktop(),
        session: noServer,
        size: const Size(1280, 800),
      );
      // App: abre o login com "Continuar sem entrar" (modo local).
      await tester.tap(find.text('Continuar sem entrar'));
      await tester.pumpAndSettle();
      expect(find.byType(DesktopShell), findsOneWidget);
      expect(tester.getSize(find.byKey(AppFrame.contentKey)).width, 1280);
    });

    testWidgets('janela estreita: celular na largura toda, sem moldura', (
      tester,
    ) async {
      await pumpBergastream(
        tester,
        platform: const AppPlatform.desktop(),
        size: const Size(700, 800),
      );
      expect(find.byType(MobileShell), findsOneWidget);
      expect(tester.getSize(find.byKey(AppFrame.contentKey)).width, 700);
      expect(find.byType(ClipRRect), findsNothing);
    });
  });
}
