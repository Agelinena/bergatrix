import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/http.dart';
import '../core/storage.dart';
import '../data/models.dart';
import 'oidc_launcher.dart';

enum SessionStatus { loggedOut, loggingIn, loggedIn }

class SessionState {
  const SessionState({
    required this.status,
    this.server,
    this.user,
    this.error,
  });

  final SessionStatus status;

  /// Endereço do servidor (na web, o próprio domínio).
  final String? server;
  final User? user;

  /// Erro do último login (mostrado na tela de login).
  final String? error;

  bool get isLoggedIn => status == SessionStatus.loggedIn;
}

/// Tokens no armazenamento seguro; cópia em memória para o interceptor.
class SessionStorage {
  SessionStorage(this._store);

  final KeyValueStore _store;

  static const _server = 'server';
  static const _user = 'user';
  static const _access = 'access_token';
  static const _refresh = 'refresh_token';
  static const _pending = 'oidc_pending';

  String? _accessToken;
  String? _refreshToken;

  String? get accessToken => _accessToken;
  String? get refreshToken => _refreshToken;

  Future<SessionState> load({String? defaultServer}) async {
    final server = await _store.read(_server) ?? defaultServer;
    _accessToken = await _store.read(_access);
    _refreshToken = await _store.read(_refresh);
    User? user;
    final raw = await _store.read(_user);
    if (raw != null) {
      try {
        user = User.fromJson(jsonDecode(raw) as Json);
      } on Object {
        user = null;
      }
    }
    final logged = _refreshToken != null && user != null && server != null;
    return SessionState(
      status: logged ? SessionStatus.loggedIn : SessionStatus.loggedOut,
      server: server,
      user: logged ? user : null,
    );
  }

  Future<void> saveLogin(String server, User user, Tokens tokens) async {
    await _store.write(_server, server);
    await saveUser(user);
    await saveTokens(tokens);
  }

  Future<void> saveUser(User user) => _store.write(
    _user,
    jsonEncode({
      'id': user.id,
      'username': user.username,
      'name': user.name,
      'email': user.email,
      'is_admin': user.isAdmin,
    }),
  );

  Future<void> saveTokens(Tokens t) async {
    _accessToken = t.access;
    _refreshToken = t.refresh;
    await _store.write(_access, t.access);
    await _store.write(_refresh, t.refresh);
  }

  Future<void> clear() async {
    _accessToken = null;
    _refreshToken = null;
    await _store.delete(_access);
    await _store.delete(_refresh);
    await _store.delete(_user);
  }

  /// Login em andamento: na web a página sai e volta do Authentik.
  Future<void> savePending(String server, String verifier) => _store.write(
    _pending,
    jsonEncode({'server': server, 'verifier': verifier}),
  );

  Future<({String server, String verifier})?> takePending() async {
    final raw = await _store.read(_pending);
    if (raw == null) return null;
    await _store.delete(_pending);
    try {
      final data = jsonDecode(raw) as Json;
      return (
        server: data['server'] as String,
        verifier: data['verifier'] as String,
      );
    } on Object {
      return null;
    }
  }
}

final initialSessionProvider = Provider<SessionState>(
  (ref) => throw UnimplementedError('initialSessionProvider não foi definido'),
);

final sessionStorageProvider = Provider<SessionStorage>(
  (ref) => SessionStorage(ref.watch(keyValueStoreProvider)),
);

final sessionProvider = NotifierProvider<SessionController, SessionState>(
  SessionController.new,
);

TokenPair parseTokenPair(Json data) => TokenPair(
  Tokens(
    access: data['access_token'] as String,
    refresh: data['refresh_token'] as String,
  ),
  User.fromJson(data['user'] as Json),
);

class TokenPair {
  const TokenPair(this.tokens, this.user);

  final Tokens tokens;
  final User user;
}

class SessionController extends Notifier<SessionState> {
  @override
  SessionState build() => ref.watch(initialSessionProvider);

  SessionStorage get _storage => ref.read(sessionStorageProvider);

  Future<bool>? _refreshing;

  /// Confere o endereço e se o servidor aceita o login pelo Authentik.
  Future<AuthConfig> checkServer(String server) async {
    final dio = createDio(baseUrl: server);
    final r = await dio.get<Json>('/api/auth/config');
    return AuthConfig.fromJson(r.data ?? const {});
  }

  /// "Entrar com o Authentik": abre o navegador e troca o código pelos
  /// tokens. Na web a página sai e o login termina em [completePendingOidc].
  Future<void> loginWithOidc(String? typedServer) async {
    final server = kIsWeb
        ? (state.server ?? webServerAddress())
        : normalizeServer(typedServer ?? '');
    if (server == null) {
      state = SessionState(
        status: SessionStatus.loggedOut,
        server: state.server,
        error: 'Digite o endereço do servidor (ex.: news.example.com).',
      );
      return;
    }
    state = SessionState(status: SessionStatus.loggingIn, server: server);
    final launcher = ref.read(oidcLauncherProvider);
    try {
      final config = await checkServer(server);
      if (!config.oidcEnabled) {
        throw const _LoginError('O servidor não está com o login pelo Authentik configurado.');
      }
      final verifier = _pkceVerifier();
      await _storage.savePending(server, verifier);
      final start = Uri.parse('$server/api/auth/oidc/start').replace(
        queryParameters: {
          'redirect': await launcher.redirect(),
          'challenge': base64Url
              .encode(sha256.convert(ascii.encode(verifier)).bytes)
              .replaceAll('=', ''),
        },
      );
      final code = await launcher.open(start);
      final pending = await _storage.takePending();
      if (code == null || pending == null) {
        throw const _LoginError('O login não terminou. Tente de novo.');
      }
      await _finish(code, pending);
    } on _LoginError catch (e) {
      state = SessionState(
        status: SessionStatus.loggedOut,
        server: server,
        error: e.message,
      );
    } on DioException catch (e) {
      state = SessionState(
        status: SessionStatus.loggedOut,
        server: server,
        error: describeError(e),
      );
    } finally {
      await launcher.cancel();
    }
  }

  /// Termina o login que voltou recarregando a página (web) ou reabrindo o
  /// app (Android).
  Future<void> completePendingOidc() async {
    final launcher = ref.read(oidcLauncherProvider);
    final code = await launcher.initialCode();
    if (code == null) return;
    launcher.clearInitialCode();
    final pending = await _storage.takePending();
    if (pending == null) return;
    state = SessionState(status: SessionStatus.loggingIn, server: pending.server);
    try {
      await _finish(code, pending);
    } on Object catch (e) {
      state = SessionState(
        status: SessionStatus.loggedOut,
        server: pending.server,
        error: describeError(e),
      );
    }
  }

  Future<void> _finish(
    String code,
    ({String server, String verifier}) pending,
  ) async {
    final dio = createDio(baseUrl: pending.server);
    final r = await dio.post<Json>(
      '/api/auth/oidc/exchange',
      data: {'code': code, 'verifier': pending.verifier},
    );
    final pair = parseTokenPair(r.data!);
    await _storage.saveLogin(pending.server, pair.user, pair.tokens);
    state = SessionState(
      status: SessionStatus.loggedIn,
      server: pending.server,
      user: pair.user,
    );
  }

  static String _pkceVerifier() {
    final random = Random.secure();
    final bytes = List<int>.generate(48, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// Renova os tokens; vários 401 ao mesmo tempo dividem uma renovação.
  Future<bool> refreshTokens() =>
      _refreshing ??= _refresh().whenComplete(() => _refreshing = null);

  Future<bool> _refresh() async {
    final server = state.server;
    final token = _storage.refreshToken;
    if (!state.isLoggedIn || server == null || token == null) return false;
    try {
      final r = await createDio(baseUrl: server).post<Json>(
        '/api/auth/refresh',
        data: {'refresh_token': token},
      );
      final pair = parseTokenPair(r.data!);
      await _storage.saveTokens(pair.tokens);
      await _storage.saveUser(pair.user);
      state = SessionState(
        status: SessionStatus.loggedIn,
        server: server,
        user: pair.user,
      );
      return true;
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 401 || code == 403) {
        await _storage.clear();
        state = SessionState(
          status: SessionStatus.loggedOut,
          server: server,
          error: 'Sessão expirada. Entre de novo.',
        );
      }
      return false;
    }
  }

  Future<void> logout() async {
    final server = state.server;
    final token = _storage.refreshToken;
    if (server != null && token != null) {
      try {
        await createDio(baseUrl: server).post<void>(
          '/api/auth/logout',
          data: {'refresh_token': token},
        );
      } on DioException {
        // Sem rede: a sessão some só neste aparelho.
      }
    }
    await _storage.clear();
    state = SessionState(status: SessionStatus.loggedOut, server: server);
  }
}

class _LoginError implements Exception {
  const _LoginError(this.message);

  final String message;
}

/// Cliente da API com o token e a renovação automática.
final dioProvider = Provider<Dio>((ref) {
  final server = ref.watch(sessionProvider.select((s) => s.server)) ?? '';
  final dio = createDio(baseUrl: server);
  dio.interceptors.add(
    AuthInterceptor(
      dio: dio,
      accessToken: () => ref.read(sessionStorageProvider).accessToken,
      refresh: () => ref.read(sessionProvider.notifier).refreshTokens(),
    ),
  );
  return dio;
});
