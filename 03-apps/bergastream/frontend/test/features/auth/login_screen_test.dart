import 'package:bergastream/app/routes.dart';
import 'package:bergastream/core/platform/app_platform.dart';
import 'package:bergastream/data/models/auth.dart';
import 'package:bergastream/data/repositories/fake_auth_repository.dart';
import 'package:bergastream/features/auth/login_screen.dart';
import 'package:bergastream/features/auth/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../app_harness.dart';
import '../../fake_oidc.dart';

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

  testWidgets('app: endereço salvo pela 0.3.x aparece sem o caminho antigo', (
    tester,
  ) async {
    await pumpBergastream(
      tester,
      session: const SessionState(
        status: SessionStatus.deslogado,
        server: 'https://musica.exemplo.com/api-access-bypass',
      ),
    );
    expect(find.text('https://musica.exemplo.com'), findsOneWidget);
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

  group('servidor com Authentik', () {
    const web = SessionState(
      status: SessionStatus.deslogado,
      server: testServer,
    );

    FakeAuthRepository authWith(AuthOptions options) =>
        FakeAuthRepository(delay: Duration.zero)
          ..authOptions = options
          ..oidcCode = 'c1';

    testWidgets('só Authentik: sem usuário e senha; entra pelo botão', (
      tester,
    ) async {
      final oidc = FakeOidcLauncher(code: 'c1');
      await pumpBergastream(
        tester,
        platform: const AppPlatform.web(),
        session: web,
        size: const Size(1200, 800),
        auth: authWith(
          const AuthOptions(oidcEnabled: true, passwordLoginEnabled: false),
        ),
        oidc: oidc,
      );
      expect(find.text('Entrar com o Authentik'), findsOneWidget);
      expect(find.text('Seu usuário'), findsNothing);
      expect(find.text('Entrar com usuário e senha'), findsNothing);

      await tester.tap(find.text('Entrar com o Authentik'));
      await tester.pumpAndSettle();
      expect(oidc.opened.single.path, '/api/auth/oidc/start');
      expect(find.byType(LoginScreen), findsNothing);
    });

    testWidgets('Authentik e senha: os dois aparecem', (tester) async {
      await pumpBergastream(
        tester,
        platform: const AppPlatform.web(),
        session: web,
        size: const Size(1200, 900),
        auth: authWith(const AuthOptions(oidcEnabled: true)),
      );
      expect(find.text('Entrar com o Authentik'), findsOneWidget);
      expect(field('Seu usuário'), findsOneWidget);
      expect(find.text('ou com usuário e senha'), findsOneWidget);
    });

    testWidgets('servidor sem resposta: mantém os dois e diz o motivo', (
      tester,
    ) async {
      await pumpBergastream(
        tester,
        platform: const AppPlatform.web(),
        session: web,
        size: const Size(1200, 900),
        auth: FakeAuthRepository(delay: Duration.zero)..authOptions = null,
      );
      expect(find.text('Entrar com o Authentik'), findsOneWidget);
      expect(field('Seu usuário'), findsOneWidget);
      expect(
        find.textContaining('As duas formas de entrar continuam aqui.'),
        findsOneWidget,
      );
    });

    testWidgets('app: "Conferir servidor" tira o botão que sobra', (
      tester,
    ) async {
      await pumpBergastream(
        tester,
        session: noServer,
        size: const Size(400, 1000),
        auth: authWith(
          const AuthOptions(oidcEnabled: true, passwordLoginEnabled: false),
        ),
      );
      // Antes de conferir: as duas.
      expect(find.text('Entrar com o Authentik'), findsOneWidget);
      expect(field('Seu usuário'), findsOneWidget);

      await tester.enterText(
        field('https://musica.meuservidor.com'),
        'musica.com',
      );
      await tester.tap(find.text('Conferir servidor'));
      await tester.pumpAndSettle();
      expect(
        find.text('Servidor conferido: entra pelo Authentik.'),
        findsOneWidget,
      );
      expect(find.text('Entrar com o Authentik'), findsOneWidget);
      expect(field('Seu usuário'), findsNothing);

      // Mexeu no endereço: volta às duas até conferir de novo.
      await tester.enterText(
        field('https://musica.meuservidor.com'),
        'outro.com',
      );
      await tester.pumpAndSettle();
      expect(field('Seu usuário'), findsOneWidget);
    });

    testWidgets('app: servidor que não existe mantém os dois', (tester) async {
      await pumpBergastream(
        tester,
        session: noServer,
        size: const Size(400, 1000),
        auth: authWith(const AuthOptions(oidcEnabled: true)),
      );
      await tester.enterText(
        field('https://musica.meuservidor.com'),
        'naoexiste.com',
      );
      await tester.tap(find.text('Conferir servidor'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Servidor não encontrado'), findsOneWidget);
      expect(find.text('Entrar com o Authentik'), findsOneWidget);
      expect(field('Seu usuário'), findsOneWidget);
    });

    testWidgets('desistiu no navegador: mostra o aviso', (tester) async {
      await pumpBergastream(
        tester,
        platform: const AppPlatform.web(),
        session: web,
        size: const Size(1200, 800),
        auth: authWith(const AuthOptions(oidcEnabled: true)),
        oidc: FakeOidcLauncher(),
      );
      await tester.tap(find.text('Entrar com o Authentik'));
      await tester.pumpAndSettle();
      expect(
        find.text('O login pelo Authentik não terminou. Tente de novo.'),
        findsOneWidget,
      );
    });
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
