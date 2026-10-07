import 'package:bergastream/app/routes.dart';
import 'package:bergastream/core/platform/app_platform.dart';
import 'package:bergastream/data/repositories/fake_auth_repository.dart';
import 'package:bergastream/features/auth/login_screen.dart';
import 'package:bergastream/features/auth/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../app_harness.dart';

void main() {
  Finder field(String hint) => find.widgetWithText(TextField, hint);

  Future<void> fill(
    WidgetTester tester, {
    String? server,
    required String user,
    required String password,
  }) async {
    if (server != null) {
      await tester.enterText(field('https://musica.meuservidor.com'), server);
    }
    await tester.enterText(field('Seu usuário'), user);
    await tester.enterText(field('Sua senha'), password);
    await tester.tap(find.text('Entrar'));
    await tester.pumpAndSettle();
  }

  testWidgets('app: 1ª abertura mostra o login com servidor e "Continuar '
      'sem entrar"', (tester) async {
    await pumpBergastream(tester, session: noServer);
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.text('Endereço do servidor'), findsOneWidget);
    expect(find.text('Continuar sem entrar'), findsOneWidget);
  });

  testWidgets('web: sem campo de servidor nem "Continuar sem entrar"', (
    tester,
  ) async {
    await pumpBergastream(
      tester,
      platform: const AppPlatform.web(),
      session: const SessionState(
        status: SessionStatus.deslogado,
        server: testServer,
      ),
      size: const Size(1200, 800),
    );
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.text('Endereço do servidor'), findsNothing);
    expect(find.text('Continuar sem entrar'), findsNothing);
  });

  testWidgets('web: nenhuma rota abre sem login', (tester) async {
    await pumpBergastream(
      tester,
      platform: const AppPlatform.web(),
      session: const SessionState(status: SessionStatus.deslogado),
      initialLocation: AppRoutes.settings,
      size: const Size(1200, 800),
    );
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.text('Seu som'), findsNothing);
  });

  testWidgets('mostra os erros abaixo do campo', (tester) async {
    await pumpBergastream(tester, session: noServer);

    await fill(tester, server: 'naoexiste.com', user: 'demo', password: 'demo');
    expect(
      find.text('Servidor não encontrado. Confira o endereço.'),
      findsOneWidget,
    );

    await fill(tester, server: 'musica.com', user: 'demo', password: 'x');
    expect(find.text('Usuário ou senha incorretos.'), findsOneWidget);
    expect(
      find.text('Servidor não encontrado. Confira o endereço.'),
      findsNothing,
    );

    await fill(tester, server: 'offline.com', user: 'demo', password: 'demo');
    expect(
      find.text('Não foi possível conectar. Verifique sua internet.'),
      findsOneWidget,
    );
  });

  testWidgets('login certo abre o Início', (tester) async {
    await pumpBergastream(tester, session: noServer);
    await fill(tester, server: 'musica.com', user: 'demo', password: 'demo');
    expect(find.text('Seu som'), findsOneWidget);
    expect(find.text('ouvidas este mês'), findsOneWidget);
  });

  testWidgets('"Continuar sem entrar" abre o app em modo local', (
    tester,
  ) async {
    await pumpBergastream(tester, session: noServer);
    await tester.tap(find.text('Continuar sem entrar'));
    await tester.pumpAndSettle();

    expect(find.text('Seu som'), findsOneWidget);
    expect(
      find.text('Entre ou baixe músicas para ver suas métricas aqui.'),
      findsOneWidget,
    );

    await tester.tap(find.text('Buscar').last);
    await tester.pumpAndSettle();
    expect(find.text('Entre para buscar músicas no servidor'), findsOneWidget);
    expect(find.text('Spotify'), findsNothing);
  });

  testWidgets('sessão expirada mostra o aviso e continua no app', (
    tester,
  ) async {
    final auth = FakeAuthRepository(delay: Duration.zero)..failRefresh = true;
    final container = await pumpBergastream(tester, auth: auth);
    await container.read(sessionProvider.notifier).refreshTokens();
    await tester.pumpAndSettle();

    expect(
      find.text('Sessão expirada. Entre para buscar no servidor.'),
      findsOneWidget,
    );
    expect(find.text('Seu som'), findsOneWidget);

    await tester.tap(find.text('Entrar').first);
    await tester.pumpAndSettle();
    expect(find.byType(LoginScreen), findsOneWidget);
  });

  testWidgets('servidor indisponível mostra o aviso', (tester) async {
    final container = await pumpBergastream(tester);
    container.read(sessionProvider.notifier).setServerAvailable(false);
    await tester.pumpAndSettle();
    expect(
      find.text('Servidor indisponível. Mostrando suas músicas baixadas.'),
      findsOneWidget,
    );

    container.read(sessionProvider.notifier).setServerAvailable(true);
    await tester.pumpAndSettle();
    expect(
      find.text('Servidor indisponível. Mostrando suas músicas baixadas.'),
      findsNothing,
    );
  });

  testWidgets('sair (app) pergunta sobre os downloads e volta ao login', (
    tester,
  ) async {
    await pumpBergastream(
      tester,
      initialLocation: AppRoutes.settings,
      size: const Size(360, 1000),
    );
    expect(find.text('Conectado como demo'), findsOneWidget);

    await tester.tap(find.text('Sair'));
    await tester.pumpAndSettle();
    expect(
      find.text('Manter as músicas baixadas neste aparelho?'),
      findsOneWidget,
    );
    await tester.tap(find.text('Manter'));
    await tester.pumpAndSettle();
    expect(find.byType(LoginScreen), findsOneWidget);
  });
}
