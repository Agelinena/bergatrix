import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_error.dart';
import '../../core/platform/app_platform.dart';
import '../../core/storage/key_value_store.dart';
import '../../data/models/auth.dart';
import '../../data/repositories/auth_repository.dart';
import 'oidc_launcher.dart';

/// Estados da sessão (Seção 2.3):
/// `semServidorConfigurado → deslogado → logando → logado`, e
/// `logado → sessaoExpirada → deslogado`.
enum SessionStatus {
  semServidorConfigurado,
  deslogado,
  logando,
  logado,
  sessaoExpirada,
}

class SessionState {
  const SessionState({
    required this.status,
    this.server,
    this.username,
    this.localMode = false,
    this.serverAvailable = true,
    this.loginError,
  });

  final SessionStatus status;

  /// Endereço do servidor (na web, o próprio domínio).
  final String? server;

  /// Usuário conectado (mantido na sessão expirada).
  final String? username;

  /// O usuário escolheu "Continuar sem entrar" (só no app).
  final bool localMode;

  /// Falso quando o servidor não responde (modo offline).
  final bool serverAvailable;

  /// Erro do último login, mostrado na tela de login.
  final AuthError? loginError;

  bool get isLoggedIn => status == SessionStatus.logado;

  /// Pode buscar, tocar por streaming e ver dados do servidor.
  bool get canUseServer => isLoggedIn && serverAvailable;

  SessionState copyWith({
    SessionStatus? status,
    String? server,
    String? username,
    bool? localMode,
    bool? serverAvailable,
    AuthError? loginError,
    bool clearLoginError = false,
    bool clearUsername = false,
  }) {
    return SessionState(
      status: status ?? this.status,
      server: server ?? this.server,
      username: clearUsername ? null : username ?? this.username,
      localMode: localMode ?? this.localMode,
      serverAvailable: serverAvailable ?? this.serverAvailable,
      loginError: clearLoginError ? null : loginError ?? this.loginError,
    );
  }
}

/// Persistência da sessão. O token fica no armazenamento seguro; na
/// simulação do Android (web) as chaves têm prefixo próprio para não
/// misturar com a sessão da versão web.
class SessionStorage {
  SessionStorage(this._store, {String prefix = ''})
    : _server = '${prefix}server',
      _username = '${prefix}username',
      _access = '${prefix}access_token',
      _refresh = '${prefix}refresh_token',
      _localMode = '${prefix}local_mode',
      _oidcPending = '${prefix}oidc_pending';

  final KeyValueStore _store;
  final String _oidcPending;
  final String _server;
  final String _username;
  final String _access;
  final String _refresh;
  final String _localMode;

  /// Cópia em memória dos tokens (o interceptor lê a cada chamada).
  String? _accessToken;
  String? _refreshToken;

  String? get accessToken => _accessToken;

  static String prefixFor(AppPlatform platform) =>
      platform.simulated ? 'sim_android.' : '';

  /// Estado inicial ao abrir o app. A validação do token no servidor entra
  /// com o cliente HTTP (Passo 4).
  Future<SessionState> load({required String? defaultServer}) async {
    final server = await _store.read(_server) ?? defaultServer;
    final username = await _store.read(_username);
    final access = await _store.read(_access);
    _accessToken = access;
    _refreshToken = await _store.read(_refresh);
    final localMode = await _store.read(_localMode) == 'true';

    final SessionStatus status;
    if (access != null && username != null && server != null) {
      status = SessionStatus.logado;
    } else if (server != null) {
      status = SessionStatus.deslogado;
    } else {
      status = SessionStatus.semServidorConfigurado;
    }
    return SessionState(
      status: status,
      server: server,
      username: status == SessionStatus.logado ? username : null,
      localMode: localMode,
    );
  }

  Future<String?> refreshToken() async =>
      _refreshToken ??= await _store.read(_refresh);

  Future<void> saveLogin(String server, String username, AuthTokens t) async {
    await _store.write(_server, server);
    await _store.write(_username, username);
    await saveTokens(t);
    await _store.write(_localMode, 'false');
  }

  Future<void> saveServer(String server) => _store.write(_server, server);

  Future<void> saveTokens(AuthTokens t) async {
    _accessToken = t.accessToken;
    _refreshToken = t.refreshToken;
    await _store.write(_access, t.accessToken);
    await _store.write(_refresh, t.refreshToken);
  }

  /// Apaga os tokens; mantém o endereço do servidor para o próximo login.
  Future<void> clearTokens() async {
    _accessToken = null;
    _refreshToken = null;
    await _store.delete(_access);
    await _store.delete(_refresh);
  }

  Future<void> clearLogin() async {
    await clearTokens();
    await _store.delete(_username);
  }

  Future<void> saveLocalMode(bool value) =>
      _store.write(_localMode, value.toString());

  /// Login pelo Authentik em andamento: servidor e verifier do PKCE. Fica
  /// guardado porque, na web, a página sai e volta do Authentik.
  Future<void> saveOidcPending(String server, String verifier) => _store.write(
    _oidcPending,
    jsonEncode({'server': server, 'verifier': verifier}),
  );

  /// Lê e apaga (uso único).
  Future<({String server, String verifier})?> takeOidcPending() async {
    final raw = await _store.read(_oidcPending);
    if (raw == null) return null;
    await _store.delete(_oidcPending);
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      return (
        server: data['server'] as String,
        verifier: data['verifier'] as String,
      );
    } on Object {
      return null;
    }
  }

  /// Só para a simulação em Ajustes (debug): estraga os tokens para a
  /// próxima chamada cair no fluxo real de sessão expirada.
  Future<void> debugInvalidateTokens() => saveTokens(
    const AuthTokens(accessToken: 'invalido', refreshToken: 'invalido'),
  );
}

/// Coloca `https://` quando falta o esquema e tira a barra final.
/// Lança [AuthException] se não parecer um endereço.
String normalizeServer(String input) {
  var value = input.trim();
  if (value.isEmpty) {
    throw const AuthException(AuthError.servidorNaoEncontrado);
  }
  if (!value.contains('://')) value = 'https://$value';
  while (value.endsWith('/')) {
    value = value.substring(0, value.length - 1);
  }
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.host.isEmpty ||
      !uri.isScheme('http') && !uri.isScheme('https')) {
    throw const AuthException(AuthError.servidorNaoEncontrado);
  }
  return value;
}

/// Endereço do servidor na web: o próprio domínio do app.
String? webServerAddress() {
  final base = Uri.base;
  if (base.isScheme('http') || base.isScheme('https')) return base.origin;
  return null;
}

/// Estado carregado em `main.dart` antes de abrir o app.
final initialSessionProvider = Provider<SessionState>(
  (ref) => throw UnimplementedError('initialSessionProvider não foi definido'),
);

/// Em `main.dart` é sobrescrito com a mesma instância que carregou a sessão
/// (para manter os tokens em memória).
final sessionStorageProvider = Provider<SessionStorage>(
  (ref) => SessionStorage(
    ref.watch(keyValueStoreProvider),
    prefix: SessionStorage.prefixFor(ref.watch(appPlatformProvider)),
  ),
);

final sessionProvider = NotifierProvider<SessionController, SessionState>(
  SessionController.new,
);

class SessionController extends Notifier<SessionState> {
  @override
  SessionState build() => ref.watch(initialSessionProvider);

  AuthRepository get _repository => ref.read(authRepositoryProvider);
  SessionStorage get _storage => ref.read(sessionStorageProvider);

  /// Access token atual (lido pelo interceptor a cada chamada).
  String? get accessToken => _storage.accessToken;

  Future<bool>? _refreshing;

  /// Entra no servidor. Na web o endereço é o próprio domínio e [server] é
  /// ignorado.
  Future<void> login({
    String? server,
    required String username,
    required String password,
  }) async {
    final previous = state;
    state = state.copyWith(
      status: SessionStatus.logando,
      clearLoginError: true,
    );
    try {
      final address = await _discover(previous, server);
      final response = await _repository.login(
        server: address,
        username: username.trim(),
        password: password,
      );
      await _storage.saveLogin(
        address,
        response.user.username,
        response.tokens,
      );
      state = SessionState(
        status: SessionStatus.logado,
        server: address,
        username: response.user.username,
      );
    } on AuthException catch (e) {
      state = previous.copyWith(loginError: e.error);
    }
  }

  /// Endereço que responde, em ordem: o salvo/digitado, na web o próprio
  /// domínio.
  Future<String> _discover(SessionState previous, String? server) =>
      ref.read(appPlatformProvider).isWeb
      ? _repository.discoverServer(previous.server ?? webServerAddress() ?? '')
      : _repository.discoverServer(normalizeServer(server ?? ''));

  /// "Conferir servidor": acha o endereço e pergunta como ele aceita o login
  /// (Authentik, senha ou os dois). Sem resposta, devolve o motivo e nenhuma
  /// opção: a tela mantém as duas formas de entrar.
  Future<ServerCheck> checkServer(String? server) async {
    try {
      final address = await _discover(state, server);
      final options = await _repository.options(address);
      return ServerCheck(
        address: address,
        options: options,
        error: options == null ? AuthError.servidorNaoEncontrado : null,
      );
    } on AuthException catch (e) {
      return ServerCheck(error: e.error);
    }
  }

  /// "Entrar com o Authentik": abre o login no navegador e, quando o
  /// servidor devolve o código, troca pelos tokens. Na web a página sai
  /// para o Authentik e o login termina em [completePendingOidc].
  Future<void> loginWithOidc({String? server}) async {
    final previous = state;
    state = state.copyWith(
      status: SessionStatus.logando,
      clearLoginError: true,
    );
    final launcher = ref.read(oidcLauncherProvider);
    try {
      final address = await _discover(previous, server);
      // Só desiste se o servidor respondeu que não tem Authentik; sem
      // resposta, tenta (a página do servidor explica se não der).
      final options = await _repository.options(address);
      if (options != null && !options.oidcEnabled) {
        throw const AuthException(AuthError.semAuthentik);
      }
      final verifier = _pkceVerifier();
      await _storage.saveOidcPending(address, verifier);
      final start = Uri.parse('$address/api/auth/oidc/start').replace(
        queryParameters: {
          'redirect': await launcher.redirect(),
          'challenge': base64Url
              .encode(sha256.convert(ascii.encode(verifier)).bytes)
              .replaceAll('=', ''),
        },
      );
      final code = await launcher.open(start);
      final pending = await _storage.takeOidcPending();
      if (code == null || pending == null) {
        throw const AuthException(AuthError.authentikFalhou);
      }
      await _finishOidc(code, pending);
    } on AuthException catch (e) {
      state = previous.copyWith(loginError: e.error);
    } finally {
      await launcher.cancel();
    }
  }

  /// Termina o login que começou antes de a página (web) ou o app
  /// (Android) recarregar: o código veio no endereço de abertura.
  Future<void> completePendingOidc() async {
    final launcher = ref.read(oidcLauncherProvider);
    final code = await launcher.initialCode();
    if (code == null) return;
    launcher.clearInitialCode();
    // Sem login em andamento (link antigo reaberto pelo sistema): ignora.
    final pending = await _storage.takeOidcPending();
    if (pending == null) return;
    final previous = state;
    state = state.copyWith(
      status: SessionStatus.logando,
      clearLoginError: true,
    );
    try {
      await _finishOidc(code, pending);
    } on AuthException catch (e) {
      state = previous.copyWith(loginError: e.error);
    }
  }

  Future<void> _finishOidc(
    String code,
    ({String server, String verifier}) pending,
  ) async {
    final response = await _repository.exchangeOidc(
      server: pending.server,
      code: code,
      verifier: pending.verifier,
    );
    await _storage.saveLogin(
      pending.server,
      response.user.username,
      response.tokens,
    );
    state = SessionState(
      status: SessionStatus.logado,
      server: pending.server,
      username: response.user.username,
    );
  }

  /// 64 caracteres aleatórios (RFC 7636: 43 a 128, sem padding).
  static String _pkceVerifier() {
    final random = Random.secure();
    final bytes = List<int>.generate(48, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// "Esqueci minha senha": o servidor manda o link para o e-mail da conta.
  Future<void> forgotPassword({String? server, required String login}) async {
    final address = await _discover(state, server);
    await _repository.forgotPassword(server: address, login: login);
  }

  /// Tokens novos depois de trocar a própria senha (as outras sessões
  /// caíram; este aparelho segue conectado).
  Future<void> replaceTokens(TokenResponse response) async {
    await _storage.saveTokens(response.tokens);
    if (state.isLoggedIn) {
      state = state.copyWith(username: response.user.username);
    }
  }

  /// "Continuar sem entrar": abre o app em modo local (só no app).
  Future<void> continueWithoutLogin() async {
    await _storage.saveLocalMode(true);
    state = state.copyWith(localMode: true, clearLoginError: true);
  }

  /// Renova os tokens. Chamadas simultâneas (vários 401 ao mesmo tempo)
  /// compartilham uma única renovação. Se falhar, a sessão expira mas o app
  /// não desloga: segue em modo local com o aviso (Seção 2.3); na web isso
  /// leva de volta ao login.
  Future<bool> refreshTokens() =>
      _refreshing ??= _refresh().whenComplete(() => _refreshing = null);

  Future<bool> _refresh() async {
    if (!state.isLoggedIn) return false;
    final refreshToken = await _storage.refreshToken();
    try {
      if (refreshToken == null) {
        throw const AuthException(AuthError.credenciaisInvalidas);
      }
      final tokens = await _repository.refresh(
        server: state.server ?? '',
        refreshToken: refreshToken,
      );
      await _storage.saveTokens(tokens);
      return true;
    } on AuthException catch (e) {
      if (e.error == AuthError.semConexao) {
        // Sem rede não dá para saber se o token ainda vale: não expira.
        state = state.copyWith(serverAvailable: false);
        return false;
      }
      await _storage.clearTokens();
      state = state.copyWith(status: SessionStatus.sessaoExpirada);
      return false;
    }
  }

  /// Confere a sessão salva ao abrir o app (`/api/auth/me`). Token vencido
  /// é renovado pelo interceptor; sem rede, entra em modo offline.
  Future<void> validate() async {
    if (!state.isLoggedIn) return;
    await _preferRootAddress();
    try {
      final user = await _repository.me();
      if (state.isLoggedIn) {
        state = state.copyWith(username: user.username, serverAvailable: true);
      }
    } on ApiException catch (e) {
      if (e.kind == ApiErrorKind.semConexao ||
          e.kind == ApiErrorKind.tempoEsgotado) {
        state = state.copyWith(serverAvailable: false);
      }
    }
  }

  /// Sessões salvas pelas versões 0.3.x usam o caminho do bypass
  /// (/api-access-bypass), que sai quando o servidor deixa o forward-auth do
  /// Authentik: volta para o endereço simples se ele responder.
  Future<void> _preferRootAddress() async {
    final server = state.server;
    if (server == null || !server.endsWith(bypassPrefix)) return;
    final root = server.substring(0, server.length - bypassPrefix.length);
    try {
      final found = await _repository.discoverServer(root);
      if (found != server && state.server == server) {
        await _storage.saveServer(found);
        state = state.copyWith(server: found);
      }
    } on Object catch (e) {
      debugPrint('Endereço do servidor não conferido: $e');
    }
  }

  /// "Sair": encerra a sessão no servidor (se der), apaga o token e volta
  /// para o login. As músicas baixadas continuam no aparelho (a pergunta
  /// fica na tela de Ajustes).
  Future<void> logout() async {
    final refreshToken = await _storage.refreshToken();
    if (refreshToken != null && state.server != null) {
      await _repository.logout(
        server: state.server!,
        refreshToken: refreshToken,
      );
    }
    await _storage.clearLogin();
    await _storage.saveLocalMode(false);
    state = SessionState(
      status: state.server == null
          ? SessionStatus.semServidorConfigurado
          : SessionStatus.deslogado,
      server: state.server,
    );
  }

  /// Servidor respondeu ou deixou de responder. A detecção automática
  /// entra no Passo 11; até lá é usado pela simulação em Ajustes (debug).
  void setServerAvailable(bool available) {
    state = state.copyWith(serverAvailable: available);
  }

  /// Simulação de Ajustes (debug): estraga os tokens e renova, caindo no
  /// fluxo real de sessão expirada.
  Future<void> debugExpireSession() async {
    await _storage.debugInvalidateTokens();
    await refreshTokens();
  }

  void clearLoginError() {
    state = state.copyWith(clearLoginError: true);
  }
}
