import 'package:bergastream/core/platform/app_platform.dart';
import 'package:bergastream/core/storage/key_value_store.dart';
import 'package:bergastream/data/models/auth.dart';
import 'package:bergastream/data/repositories/auth_repository.dart';
import 'package:bergastream/data/repositories/fake_auth_repository.dart';
import 'package:bergastream/features/auth/session.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late MemoryKeyValueStore store;
  late FakeAuthRepository auth;

  ProviderContainer containerFor(
    SessionState initial, {
    AppPlatform platform = const AppPlatform.app(),
  }) {
    final container = ProviderContainer(
      overrides: [
        appPlatformProvider.overrideWithValue(platform),
        keyValueStoreProvider.overrideWithValue(store),
        initialSessionProvider.overrideWithValue(initial),
        authRepositoryProvider.overrideWithValue(auth),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  setUp(() {
    store = MemoryKeyValueStore();
    auth = FakeAuthRepository(delay: Duration.zero);
  });

  const noServer = SessionState(status: SessionStatus.semServidorConfigurado);

  group('carregar ao abrir', () {
    test('sem nada salvo: sem servidor configurado', () async {
      final s = await SessionStorage(store).load(defaultServer: null);
      expect(s.status, SessionStatus.semServidorConfigurado);
    });

    test('na web o servidor é o próprio domínio: deslogado', () async {
      final s = await SessionStorage(
        store,
      ).load(defaultServer: 'https://app.exemplo.com');
      expect(s.status, SessionStatus.deslogado);
      expect(s.server, 'https://app.exemplo.com');
    });

    test('com token salvo: logado', () async {
      store.values.addAll({
        'server': 'https://s.com',
        'username': 'demo',
        'access_token': 'a',
        'refresh_token': 'r',
      });
      final s = await SessionStorage(store).load(defaultServer: null);
      expect(s.status, SessionStatus.logado);
      expect(s.username, 'demo');
    });

    test('a simulação do Android usa chaves separadas', () async {
      store.values.addAll({
        'server': 'https://s.com',
        'username': 'demo',
        'access_token': 'a',
      });
      final s = await SessionStorage(
        store,
        prefix: SessionStorage.prefixFor(const AppPlatform.simulatedAndroid()),
      ).load(defaultServer: null);
      expect(s.status, SessionStatus.semServidorConfigurado);
    });
  });

  group('login', () {
    test('passa por logando e chega em logado, salvando o token', () async {
      final container = containerFor(noServer);
      final statuses = <SessionStatus>[];
      container.listen(sessionProvider, (_, next) => statuses.add(next.status));

      await container
          .read(sessionProvider.notifier)
          .login(
            server: 'musica.exemplo.com',
            username: 'demo',
            password: 'demo',
          );

      expect(statuses, [SessionStatus.logando, SessionStatus.logado]);
      final s = container.read(sessionProvider);
      expect(s.server, 'https://musica.exemplo.com');
      expect(s.username, 'demo');
      expect(store.values['access_token'], isNotNull);
    });

    test('senha errada: volta ao estado anterior com o erro', () async {
      final container = containerFor(noServer);
      await container
          .read(sessionProvider.notifier)
          .login(server: 'musica.exemplo.com', username: 'demo', password: 'x');
      final s = container.read(sessionProvider);
      expect(s.status, SessionStatus.semServidorConfigurado);
      expect(s.loginError, AuthError.credenciaisInvalidas);
      expect(store.values['access_token'], isNull);
    });

    test('servidor inexistente ou endereço vazio', () async {
      final container = containerFor(noServer);
      final controller = container.read(sessionProvider.notifier);

      await controller.login(
        server: 'naoexiste.com',
        username: 'demo',
        password: 'demo',
      );
      expect(
        container.read(sessionProvider).loginError,
        AuthError.servidorNaoEncontrado,
      );

      await controller.login(server: '  ', username: 'demo', password: 'demo');
      expect(
        container.read(sessionProvider).loginError,
        AuthError.servidorNaoEncontrado,
      );
    });

    test('sem conexão', () async {
      final container = containerFor(noServer);
      await container
          .read(sessionProvider.notifier)
          .login(server: 'offline.com', username: 'demo', password: 'demo');
      expect(container.read(sessionProvider).loginError, AuthError.semConexao);
    });

    test('na web usa o próprio domínio e ignora o campo de servidor', () async {
      final container = containerFor(
        const SessionState(
          status: SessionStatus.deslogado,
          server: 'https://app.exemplo.com',
        ),
        platform: const AppPlatform.web(),
      );
      await container
          .read(sessionProvider.notifier)
          .login(server: 'naoexiste.com', username: 'demo', password: 'demo');
      final s = container.read(sessionProvider);
      expect(s.status, SessionStatus.logado);
      expect(s.server, 'https://app.exemplo.com');
    });

    test('um login novo limpa o erro anterior', () async {
      final container = containerFor(noServer);
      final controller = container.read(sessionProvider.notifier);
      await controller.login(server: 's.com', username: 'demo', password: 'x');
      await controller.login(
        server: 's.com',
        username: 'demo',
        password: 'demo',
      );
      expect(container.read(sessionProvider).loginError, isNull);
    });
  });

  test('continuar sem entrar ativa e salva o modo local', () async {
    final container = containerFor(noServer);
    await container.read(sessionProvider.notifier).continueWithoutLogin();
    expect(container.read(sessionProvider).localMode, isTrue);
    expect(store.values['local_mode'], 'true');
  });

  group('renovação do token', () {
    const logged = SessionState(
      status: SessionStatus.logado,
      server: 'https://s.com',
      username: 'demo',
    );

    test('sucesso: continua logado com tokens novos', () async {
      store.values['refresh_token'] = 'r0';
      final container = containerFor(logged);
      await container.read(sessionProvider.notifier).refreshTokens();
      expect(container.read(sessionProvider).status, SessionStatus.logado);
      expect(store.values['refresh_token'], isNot('r0'));
    });

    test('falha: sessão expirada sem deslogar', () async {
      store.values['refresh_token'] = 'r0';
      auth.failRefresh = true;
      final container = containerFor(logged);
      await container.read(sessionProvider.notifier).refreshTokens();
      final s = container.read(sessionProvider);
      expect(s.status, SessionStatus.sessaoExpirada);
      expect(s.username, 'demo');
      expect(s.server, 'https://s.com');
      expect(store.values['access_token'], isNull);
    });
  });

  test(
    'sair apaga o token, mantém o servidor e volta para deslogado',
    () async {
      store.values.addAll({
        'server': 'https://s.com',
        'username': 'demo',
        'access_token': 'a',
        'refresh_token': 'r',
        'local_mode': 'true',
      });
      final container = containerFor(
        const SessionState(
          status: SessionStatus.logado,
          server: 'https://s.com',
          username: 'demo',
          localMode: true,
        ),
      );
      await container.read(sessionProvider.notifier).logout();
      final s = container.read(sessionProvider);
      expect(s.status, SessionStatus.deslogado);
      expect(s.server, 'https://s.com');
      expect(s.localMode, isFalse);
      expect(store.values.containsKey('access_token'), isFalse);
      expect(store.values['server'], 'https://s.com');
    },
  );

  test('renovações simultâneas viram uma só', () async {
    store.values['refresh_token'] = 'r0';
    final container = containerFor(
      const SessionState(
        status: SessionStatus.logado,
        server: 'https://s.com',
        username: 'demo',
      ),
    );
    final controller = container.read(sessionProvider.notifier);
    final results = await Future.wait([
      controller.refreshTokens(),
      controller.refreshTokens(),
      controller.refreshTokens(),
    ]);
    expect(results, [true, true, true]);
    expect(auth.refreshCount, 1);
  });

  test('sem rede a renovação não expira a sessão', () async {
    store.values['refresh_token'] = 'r0';
    final container = containerFor(
      const SessionState(
        status: SessionStatus.logado,
        server: 'https://offline.com',
        username: 'demo',
      ),
    );
    expect(
      await container.read(sessionProvider.notifier).refreshTokens(),
      isFalse,
    );
    final s = container.read(sessionProvider);
    expect(s.status, SessionStatus.logado);
    expect(s.serverAvailable, isFalse);
  });

  group('validar ao abrir', () {
    const logged = SessionState(
      status: SessionStatus.logado,
      server: 'https://s.com',
      username: 'antigo',
    );

    test('atualiza o usuário com o do servidor', () async {
      final container = containerFor(logged);
      await container.read(sessionProvider.notifier).validate();
      expect(container.read(sessionProvider).username, 'demo');
    });

    test('sem rede entra em modo offline sem deslogar', () async {
      auth.meFails = true;
      final container = containerFor(logged);
      await container.read(sessionProvider.notifier).validate();
      final s = container.read(sessionProvider);
      expect(s.isLoggedIn, isTrue);
      expect(s.serverAvailable, isFalse);
    });
  });

  test('servidor indisponível tira o acesso ao servidor', () {
    final container = containerFor(
      const SessionState(status: SessionStatus.logado, username: 'demo'),
    );
    container.read(sessionProvider.notifier).setServerAvailable(false);
    final s = container.read(sessionProvider);
    expect(s.isLoggedIn, isTrue);
    expect(s.canUseServer, isFalse);
  });

  test('normalizeServer', () {
    expect(normalizeServer('musica.com/'), 'https://musica.com');
    expect(
      normalizeServer(' http://192.168.0.10:8000 '),
      'http://192.168.0.10:8000',
    );
    expect(() => normalizeServer('ftp://x.com'), throwsA(isA<AuthException>()));
  });
}
