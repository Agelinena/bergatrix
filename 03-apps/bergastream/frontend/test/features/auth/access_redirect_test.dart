import 'package:bergastream/features/auth/access_redirect.dart';
import 'package:bergastream/features/auth/session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const login = '/entrar';
  const home = '/inicio';

  String? redirect(
    SessionState session, {
    required bool isWeb,
    String location = home,
  }) => accessRedirect(
    session: session,
    isWeb: isWeb,
    location: location,
    loginRoute: login,
    homeRoute: home,
    publicRoutes: const {'/dev/gallery'},
  );

  const noServer = SessionState(status: SessionStatus.semServidorConfigurado);
  const loggedOut = SessionState(status: SessionStatus.deslogado);
  const logging = SessionState(status: SessionStatus.logando);
  const logged = SessionState(status: SessionStatus.logado);
  const expired = SessionState(status: SessionStatus.sessaoExpirada);
  const local = SessionState(status: SessionStatus.deslogado, localMode: true);

  group('web', () {
    test('sem sessão, toda rota vai para o login', () {
      for (final s in [noServer, loggedOut, logging, expired, local]) {
        expect(redirect(s, isWeb: true), login, reason: '${s.status}');
        expect(redirect(s, isWeb: true, location: '/buscar'), login);
        expect(redirect(s, isWeb: true, location: login), isNull);
      }
    });

    test('logado entra no app e sai do login', () {
      expect(redirect(logged, isWeb: true), isNull);
      expect(redirect(logged, isWeb: true, location: login), home);
    });
  });

  group('app (Android/desktop)', () {
    test('1ª abertura sem servidor mostra o login', () {
      expect(redirect(noServer, isWeb: false), login);
      expect(redirect(loggedOut, isWeb: false), login);
    });

    test('modo local abre o app e ainda permite ir ao login', () {
      expect(redirect(local, isWeb: false), isNull);
      expect(redirect(local, isWeb: false, location: login), isNull);
    });

    test('sessão expirada continua no app', () {
      expect(redirect(expired, isWeb: false), isNull);
      expect(redirect(expired, isWeb: false, location: login), isNull);
    });

    test('logado sai do login para o Início', () {
      expect(redirect(logged, isWeb: false, location: login), home);
    });
  });

  test('rotas públicas (galeria) abrem sem sessão', () {
    expect(redirect(noServer, isWeb: true, location: '/dev/gallery'), isNull);
  });
}
