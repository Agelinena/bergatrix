// Fluxo principal de ponta a ponta com repositórios fictícios:
// login → Início → busca → tocar → player grande → fila → Biblioteca.
//
// No aparelho: flutter test integration_test -d <id>
// Sem aparelho:  flutter test integration_test -d flutter-tester
import 'package:bergastream/app/app_shell.dart';
import 'package:bergastream/app/desktop_shell.dart';
import 'package:bergastream/core/platform/app_platform.dart';
import 'package:bergastream/features/player/full_player.dart';
import 'package:bergastream/features/player/queue_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/app_harness.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Finder field(String hint) => find.widgetWithText(TextField, hint);

  testWidgets('app: entrar, buscar, tocar e abrir a fila', (tester) async {
    await pumpBergastream(tester, session: noServer);

    await tester.enterText(
      field('https://musica.meuservidor.com'),
      'musica.com',
    );
    await tester.enterText(field('Seu usuário'), 'demo');
    await tester.enterText(field('Sua senha'), 'demo');
    await tester.tap(find.text('Entrar'));
    await tester.pumpAndSettle();
    expect(find.text('Seu som'), findsOneWidget);

    await tester.tap(find.text('Buscar').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'queen');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bohemian Rhapsody'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.pause), findsOneWidget);

    await tester.tap(find.text('Queen · A Night at the Opera'));
    await tester.pumpAndSettle();
    expect(find.byType(FullPlayer), findsOneWidget);
    await tester.tap(find.byTooltip('Fila'));
    await tester.pumpAndSettle();
    expect(find.byType(QueuePanel), findsOneWidget);
    await tester.tap(find.byTooltip('Fechar'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Biblioteca').last);
    await tester.pumpAndSettle();
    expect(find.text('Nova playlist'), findsOneWidget);
  });

  testWidgets('navegador: login obrigatório e layout largo', (tester) async {
    await pumpBergastream(
      tester,
      platform: const AppPlatform.web(),
      session: noServer,
      size: const Size(1280, 800),
    );
    expect(field('https://musica.meuservidor.com'), findsNothing);
    await tester.enterText(field('Seu usuário'), 'demo');
    await tester.enterText(field('Sua senha'), 'demo');
    await tester.tap(find.text('Entrar'));
    await tester.pumpAndSettle();
    expect(find.text('Seu som'), findsOneWidget);
    // Barra lateral do navegador no lugar da barra inferior de abas.
    expect(find.byType(DesktopShell), findsOneWidget);
    expect(find.byType(MobileShell), findsNothing);
  });
}
