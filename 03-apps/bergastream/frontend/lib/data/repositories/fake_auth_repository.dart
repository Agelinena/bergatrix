import '../../core/network/api_error.dart';
import '../models/auth.dart';
import 'auth_repository.dart';

/// Autenticação simulada, usada nos testes.
///
/// - usuário **demo** e senha **demo** entram;
/// - endereço com "naoexiste" → servidor não encontrado;
/// - endereço com "offline" → sem conexão;
/// - [failRefresh] (ou refresh token começando com "invalido") faz a
///   renovação falhar; [refreshCount] conta as renovações.
class FakeAuthRepository implements AuthRepository {
  FakeAuthRepository({this.delay = const Duration(milliseconds: 500)});

  final Duration delay;
  bool failRefresh = false;
  bool meFails = false;
  int refreshCount = 0;
  var _counter = 0;

  static const user = AuthUser(id: 'u1', username: 'demo', name: 'Demo');

  @override
  Future<TokenResponse> login({
    required String server,
    required String username,
    required String password,
  }) async {
    await Future<void>.delayed(delay);
    _checkServer(server);
    if (username.trim() != 'demo' || password != 'demo') {
      throw const AuthException(AuthError.credenciaisInvalidas);
    }
    final t = _tokens();
    return TokenResponse(
      accessToken: t.accessToken,
      refreshToken: t.refreshToken,
      expiresIn: 900,
      user: user,
    );
  }

  /// Endereço que a descoberta devolve no lugar do digitado (ex.: bypass).
  final discovered = <String, String>{};

  @override
  Future<String> discoverServer(String server) async {
    _checkServer(server);
    return discovered[server] ?? server;
  }

  @override
  Future<AuthTokens> refresh({
    required String server,
    required String refreshToken,
  }) async {
    refreshCount++;
    await Future<void>.delayed(delay);
    if (failRefresh || refreshToken.startsWith('invalido')) {
      throw const AuthException(AuthError.credenciaisInvalidas);
    }
    _checkServer(server);
    return _tokens();
  }

  @override
  Future<void> logout({
    required String server,
    required String refreshToken,
  }) async {}

  @override
  Future<AuthUser> me() async {
    if (meFails) throw const ApiException(ApiErrorKind.semConexao);
    return user;
  }

  /// O que o servidor falso diz aceitar (padrão: só senha). Nulo: não
  /// respondeu.
  AuthOptions? authOptions = const AuthOptions();

  @override
  Future<AuthOptions?> options(String server) async {
    _checkServer(server);
    return authOptions;
  }

  /// Pedidos de "esqueci minha senha" recebidos.
  final forgotten = <String>[];

  @override
  Future<void> forgotPassword({
    required String server,
    required String login,
  }) async {
    _checkServer(server);
    forgotten.add(login);
  }

  /// Código que o "Authentik" devolve e o verifier esperado (PKCE).
  String? oidcCode;
  String? oidcVerifier;

  /// Recebe o verifier de cada troca (para conferir o PKCE nos testes).
  void Function(String verifier)? onExchange;

  @override
  Future<TokenResponse> exchangeOidc({
    required String server,
    required String code,
    required String verifier,
  }) async {
    _checkServer(server);
    onExchange?.call(verifier);
    if (code != oidcCode ||
        (oidcVerifier != null && verifier != oidcVerifier)) {
      throw const AuthException(AuthError.authentikFalhou);
    }
    final t = _tokens();
    return TokenResponse(
      accessToken: t.accessToken,
      refreshToken: t.refreshToken,
      expiresIn: 900,
      user: user,
    );
  }

  void _checkServer(String server) {
    if (server.contains('offline')) {
      throw const AuthException(AuthError.semConexao);
    }
    if (server.contains('naoexiste')) {
      throw const AuthException(AuthError.servidorNaoEncontrado);
    }
  }

  AuthTokens _tokens() {
    _counter++;
    return AuthTokens(
      accessToken: 'fake-access-$_counter',
      refreshToken: 'fake-refresh-$_counter',
    );
  }
}
