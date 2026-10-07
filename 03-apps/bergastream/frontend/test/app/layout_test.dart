import 'package:bergastream/app/app_frame.dart';
import 'package:bergastream/app/app_shell.dart';
import 'package:bergastream/app/desktop_shell.dart';
import 'package:bergastream/core/platform/app_platform.dart';
import 'package:bergastream/features/player/mini_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../app_harness.dart';

void main() {
  testWidgets('web larga: layout de navegador com barra lateral e player', (
    tester,
  ) async {
    await pumpBergastream(
      tester,
      platform: const AppPlatform.web(),
      size: const Size(1280, 800),
    );
    expect(find.byType(DesktopShell), findsOneWidget);
    expect(find.text('Sua biblioteca'), findsOneWidget);
    // Sem faixa carregada, nem barra do player nem mini player.
    expect(find.byTooltip('Fila'), findsNothing);
    expect(find.byType(MiniPlayer), findsNothing);
    expect(tester.getSize(find.byKey(AppFrame.contentKey)).width, 1280);
  });

  testWidgets('web: navegar pela barra lateral troca a tela', (tester) async {
    await pumpBergastream(
      tester,
      platform: const AppPlatform.web(),
      size: const Size(1280, 800),
    );
    await tester.tap(find.text('Buscar'));
    await tester.pumpAndSettle();
    expect(find.text('Músicas, artistas, álbuns ou link'), findsOneWidget);

    await tester.tap(find.text('Sua biblioteca'));
    await tester.pumpAndSettle();
    expect(find.text('Biblioteca'), findsOneWidget);

    await tester.tap(find.text('Ajustes'));
    await tester.pumpAndSettle();
    expect(find.text('Qualidade de streaming'), findsOneWidget);
    // Web não tem downloads.
    expect(find.text('Offline'), findsNothing);
  });

  testWidgets('web estreita (celular no navegador): layout de celular', (
    tester,
  ) async {
    await pumpBergastream(
      tester,
      platform: const AppPlatform.web(),
      size: const Size(400, 800),
    );
    expect(find.byType(MobileShell), findsOneWidget);
    expect(find.byType(DesktopShell), findsNothing);
  });

  testWidgets('simulação do Android: celular numa coluna de 430 px', (
    tester,
  ) async {
    await pumpBergastream(
      tester,
      platform: const AppPlatform.simulatedAndroid(),
      size: const Size(1280, 800),
    );
    expect(find.byType(MobileShell), findsOneWidget);
    expect(tester.getSize(find.byKey(AppFrame.contentKey)).width, 430);
  });

  testWidgets('modo local: Biblioteca vazia', (tester) async {
    await pumpBergastream(tester, session: noServer.copyWith(localMode: true));
    await tester.tap(find.text('Biblioteca').last);
    await tester.pumpAndSettle();
    expect(find.text('Nenhuma playlist neste aparelho.'), findsOneWidget);
  });
}
