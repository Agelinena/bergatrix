import 'package:bergastream/app/dev/gallery_screen.dart';
import 'package:bergastream/app/not_found_screen.dart';
import 'package:bergastream/core/platform/app_platform.dart';
import 'package:bergastream/app/routes.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_harness.dart';

void main() {
  testWidgets('logado, o app abre no Início', (tester) async {
    await pumpBergastream(tester);
    expect(find.text('Seu som'), findsOneWidget);
  });

  testWidgets('em debug a galeria abre em /dev/gallery sem login', (
    tester,
  ) async {
    await pumpBergastream(
      tester,
      session: noServer,
      initialLocation: AppRoutes.gallery,
    );
    expect(find.byType(GalleryScreen), findsOneWidget);
  });
  testWidgets('a raiz "/" abre o Início', (tester) async {
    await pumpBergastream(tester, initialLocation: '/');
    expect(find.text('Seu som'), findsOneWidget);
  });

  testWidgets('web sem sessão: "/" vai para o login', (tester) async {
    await pumpBergastream(
      tester,
      platform: const AppPlatform.web(),
      session: noServer,
      initialLocation: '/',
      size: const Size(1280, 800),
    );
    expect(find.text('Seu som'), findsNothing);
    expect(find.text('Entrar'), findsWidgets);
  });

  testWidgets('endereço inexistente mostra a página em português', (
    tester,
  ) async {
    await pumpBergastream(tester, initialLocation: '/nao-existe');
    expect(find.text(NotFoundScreen.title), findsOneWidget);
    await tester.tap(find.text('Ir para o Início'));
    await tester.pumpAndSettle();
    expect(find.text('Seu som'), findsOneWidget);
  });
}
