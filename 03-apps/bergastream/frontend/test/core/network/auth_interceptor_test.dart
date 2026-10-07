import 'package:bergastream/core/network/api_client.dart';
import 'package:bergastream/core/platform/app_platform.dart';
import 'package:bergastream/core/storage/key_value_store.dart';
import 'package:bergastream/data/repositories/auth_repository.dart';
import 'package:bergastream/data/repositories/fake_auth_repository.dart';
import 'package:bergastream/features/auth/session.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../fake_http.dart';

void main() {
  late FakeAuthRepository auth;
  late ProviderContainer container;
  late MemoryKeyValueStore store;

  setUp(() async {
    auth = FakeAuthRepository(delay: const Duration(milliseconds: 20));
    store = MemoryKeyValueStore({
      'server': 'https://s.com',
      'username': 'demo',
      'access_token': 'vencido',
      'refresh_token': 'r0',
    });
    final storage = SessionStorage(store);
    final initial = await storage.load(defaultServer: null);
    container = ProviderContainer(
      overrides: [
        appPlatformProvider.overrideWithValue(const AppPlatform.app()),
        keyValueStoreProvider.overrideWithValue(store),
        sessionStorageProvider.overrideWithValue(storage),
        initialSessionProvider.overrideWithValue(initial),
        authRepositoryProvider.overrideWithValue(auth),
      ],
    );
    addTearDown(container.dispose);
  });

  Dio dioWith(FakeAdapter adapter) {
    final dio = createDio(baseUrl: 'https://s.com')
      ..httpClientAdapter = adapter;
    final session = container.read(sessionProvider.notifier);
    dio.interceptors.add(
      AuthInterceptor(
        dio: dio,
        accessToken: () => session.accessToken,
        refresh: session.refreshTokens,
      ),
    );
    return dio;
  }

  /// Servidor que só aceita tokens emitidos pela renovação fake.
  FakeAdapter server() => FakeAdapter((o) async {
    final token = o.headers['Authorization'] as String?;
    final valid = token != null && token.startsWith('Bearer fake-access-');
    return jsonBody({'ok': valid}, status: valid ? 200 : 401);
  });

  test('coloca o token no cabeçalho', () async {
    final adapter = server();
    await dioWith(adapter)
        .get<dynamic>('/x')
        .catchError((_) => Response(requestOptions: RequestOptions()));
    expect(adapter.requests.first.headers['Authorization'], 'Bearer vencido');
  });

  test('401 renova o token e repete a chamada', () async {
    final adapter = server();
    final response = await dioWith(adapter).get<Map<String, dynamic>>('/x');
    expect(response.data, {'ok': true});
    expect(auth.refreshCount, 1);
    expect(store.values['refresh_token'], isNot('r0'));
  });

  test('chamadas simultâneas fazem uma única renovação', () async {
    final adapter = server();
    final dio = dioWith(adapter);
    final responses = await Future.wait([
      for (var i = 0; i < 5; i++) dio.get<Map<String, dynamic>>('/x/$i'),
    ]);
    expect(responses.every((r) => r.data!['ok'] == true), isTrue);
    expect(auth.refreshCount, 1);
  });

  test(
    'renovação recusada: sessão expirada e o erro chega a quem chamou',
    () async {
      auth.failRefresh = true;
      final dio = dioWith(server());
      await expectLater(dio.get<dynamic>('/x'), throwsA(isA<DioException>()));
      expect(
        container.read(sessionProvider).status,
        SessionStatus.sessaoExpirada,
      );
      expect(auth.refreshCount, 1);
    },
  );

  test('não renova duas vezes a mesma chamada', () async {
    // Servidor que recusa qualquer token.
    final adapter = FakeAdapter((_) async => jsonBody({}, status: 401));
    await expectLater(
      dioWith(adapter).get<dynamic>('/x'),
      throwsA(isA<DioException>()),
    );
    expect(adapter.requests, hasLength(2));
    expect(auth.refreshCount, 1);
  });
}
