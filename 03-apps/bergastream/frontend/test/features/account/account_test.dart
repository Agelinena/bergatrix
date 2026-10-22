import 'package:bergastream/app/routes.dart';
import 'package:bergastream/core/platform/app_platform.dart';
import 'package:bergastream/data/models/account.dart';
import 'package:bergastream/data/models/auth.dart';
import 'package:bergastream/data/repositories/account_repository.dart';
import 'package:bergastream/data/repositories/fake_auth_repository.dart';
import 'package:bergastream/features/account/account_card.dart';
import 'package:bergastream/features/auth/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../app_harness.dart';

const ana = Account(
  id: 'u2',
  username: 'ana',
  name: 'Ana',
  email: 'ana@example.com',
  hasPassword: true,
  sessions: 2,
);

void main() {
  Future<void> settings(WidgetTester tester, FakeAccountRepository accounts) =>
      pumpBergastream(
        tester,
        size: const Size(420, 2600),
        initialLocation: AppRoutes.settings,
        accounts: accounts,
      );

  Future<void> users(WidgetTester tester, FakeAccountRepository accounts) =>
      pumpBergastream(
        tester,
        size: const Size(420, 1400),
        initialLocation: AppRoutes.adminUsers,
        accounts: accounts,
      );

  group('Ajustes → Conta', () {
    testWidgets('conta daqui: editar perfil e trocar senha', (tester) async {
      final accounts = FakeAccountRepository();
      await settings(tester, accounts);
      expect(find.text('Conta'), findsOneWidget);
      expect(find.text('Demo · demo'), findsOneWidget);
      expect(find.text('Gerenciar no Authentik'), findsNothing);

      await tester.tap(find.text('Editar perfil'));
      await tester.pumpAndSettle();
      expect(find.text(linkWarning), findsNothing, reason: 'sem Authentik');
      await tester.enterText(find.byType(TextField).first, 'Demo Silva');
      await tester.tap(find.text('Salvar'));
      await tester.pumpAndSettle();
      expect(accounts.accounts.first.name, 'Demo Silva');
      expect(find.text('Demo Silva · demo'), findsOneWidget);

      await tester.tap(find.text('Trocar senha'));
      await tester.pumpAndSettle();
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'senha-atual');
      await tester.enterText(fields.at(1), 'nova-senha-1');
      await tester.enterText(fields.at(2), 'outra-senha');
      await tester.tap(find.text('Salvar'));
      await tester.pumpAndSettle();
      expect(find.text('As senhas novas não conferem.'), findsOneWidget);
      await tester.enterText(fields.at(2), 'nova-senha-1');
      await tester.tap(find.text('Salvar'));
      await tester.pumpAndSettle();
      expect(find.text('Senha trocada'), findsOneWidget);
    });

    testWidgets('conta ligada ao Authentik: só leitura e atalho para lá', (
      tester,
    ) async {
      openedLinks.clear();
      final accounts = FakeAccountRepository(
        oidcEnabled: true,
        passwordLoginEnabled: false,
        accounts: [
          const Account(
            id: 'u1',
            username: 'demo',
            name: 'Demo',
            linked: true,
            managedByAuthentik: true,
          ),
        ],
      );
      await settings(tester, accounts);
      expect(find.text('Editar perfil'), findsNothing);
      expect(find.text('Trocar senha'), findsNothing);
      expect(
        find.text('Usuário, e-mail e senha vêm do Authentik.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Gerenciar no Authentik'));
      await tester.pumpAndSettle();
      expect(openedLinks, ['https://authentik.example.com/if/user/#/settings']);
    });

    testWidgets('ainda não ligada: a pessoa só muda o nome', (tester) async {
      await settings(tester, FakeAccountRepository(oidcEnabled: true));
      await tester.tap(find.text('Editar perfil'));
      await tester.pumpAndSettle();
      expect(find.text(selfLinkNote), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('Usuário'), findsNothing);
    });

    testWidgets('admin abre "Usuários"', (tester) async {
      await settings(tester, FakeAccountRepository(accounts: null));
      await tester.tap(find.text('Usuários'));
      await tester.pumpAndSettle();
      expect(find.text('E-mail: ligado'), findsOneWidget);
    });
  });

  group('Usuários (admin)', () {
    FakeAccountRepository withAna({bool oidc = false, bool linked = false}) =>
        FakeAccountRepository(oidcEnabled: oidc)
          ..accounts.add(
            Account(
              id: ana.id,
              username: ana.username,
              name: ana.name,
              email: ana.email,
              hasPassword: true,
              sessions: 2,
              linked: linked,
              managedByAuthentik: oidc && linked,
            ),
          );

    Future<void> openAna(WidgetTester tester) async {
      await tester.tap(find.text('Ana'));
      await tester.pumpAndSettle();
    }

    testWidgets('lista com situação de cada conta', (tester) async {
      await users(tester, withAna(oidc: true));
      expect(find.text('2 contas'), findsOneWidget);
      expect(find.text('ana · ana@example.com'), findsOneWidget);
      expect(find.text('não ligada · 2 aparelhos'), findsOneWidget);
      expect(find.text('Abrir no Authentik'), findsOneWidget);
    });

    testWidgets('criar conta com convite', (tester) async {
      final accounts = withAna();
      await users(tester, accounts);
      await tester.tap(find.text('Novo usuário'));
      await tester.pumpAndSettle();
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'bia');
      await tester.enterText(fields.at(1), 'Bia');
      await tester.enterText(fields.at(2), 'bia@example.com');
      await tester.tap(find.text('Criar'));
      await tester.pumpAndSettle();
      expect(accounts.accounts.last.username, 'bia');
      expect(find.text('Conta criada e convite enviado'), findsOneWidget);
      expect(find.text('Bia'), findsOneWidget);
    });

    testWidgets('senha temporária aparece uma vez para copiar', (tester) async {
      final accounts = withAna();
      await users(tester, accounts);
      await openAna(tester);
      await tester.tap(find.text('Redefinir senha'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Gerar senha temporária'));
      await tester.pumpAndSettle();
      expect(accounts.resets, [('u2', false)]);
      expect(find.text('Temp4Senha7x'), findsOneWidget);
      await tester.tap(find.text('Fechar'));
      await tester.pumpAndSettle();
    });

    testWidgets('link de senha por e-mail', (tester) async {
      final accounts = withAna();
      await users(tester, accounts);
      await openAna(tester);
      await tester.tap(find.text('Redefinir senha'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Enviar link por e-mail'));
      await tester.pumpAndSettle();
      expect(accounts.resets, [('u2', true)]);
      expect(find.text('Link enviado para ana@example.com'), findsOneWidget);
    });

    testWidgets('conta ligada: identidade e senha só no Authentik', (
      tester,
    ) async {
      await users(tester, withAna(oidc: true, linked: true));
      await openAna(tester);
      expect(find.text('Vêm do Authentik: altere lá'), findsOneWidget);
      expect(
        find.text('A senha é a do Authentik: redefina lá'),
        findsOneWidget,
      );
      expect(find.text('Desligar do Authentik'), findsOneWidget);
      // Tocar no item desabilitado não abre nada.
      await tester.tap(find.text('Editar nome, usuário e e-mail'));
      await tester.pumpAndSettle();
      expect(find.text('Editar Ana'), findsNothing);
    });

    testWidgets('ainda não ligada: aviso ao editar', (tester) async {
      await users(tester, withAna(oidc: true));
      await openAna(tester);
      await tester.tap(find.text('Editar nome, usuário e e-mail'));
      await tester.pumpAndSettle();
      expect(find.text(linkWarning), findsOneWidget);
    });

    testWidgets('desativar, avisar e mandar aviso livre', (tester) async {
      final accounts = withAna();
      await users(tester, accounts);
      await openAna(tester);
      await tester.tap(find.text('Desativar conta'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Desativar e avisar'));
      await tester.pumpAndSettle();
      expect(accounts.accounts.last.disabled, isTrue);
      expect(find.textContaining('desativada'), findsWidgets);

      await openAna(tester);
      await tester.tap(find.text('Mandar aviso por e-mail'));
      await tester.pumpAndSettle();
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'Servidor em manutenção');
      await tester.enterText(fields.at(1), 'Amanhã às 10h.');
      await tester.tap(find.text('Enviar'));
      await tester.pumpAndSettle();
      expect(accounts.notices, [('u2', 'Servidor em manutenção')]);
    });
  });

  testWidgets('login: "Esqueci minha senha" pede o link', (tester) async {
    final auth = FakeAuthRepository(delay: Duration.zero)
      ..authOptions = const AuthOptions(passwordResetEnabled: true);
    await pumpBergastream(
      tester,
      platform: const AppPlatform.web(),
      session: const SessionState(
        status: SessionStatus.deslogado,
        server: testServer,
      ),
      size: const Size(1200, 900),
      auth: auth,
    );
    await tester.tap(find.text('Esqueci minha senha'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'ana@example.com');
    await tester.tap(find.text('Enviar link'));
    await tester.pumpAndSettle();
    expect(auth.forgotten, ['ana@example.com']);
    expect(find.textContaining('o link chega em instantes'), findsOneWidget);
  });
}
