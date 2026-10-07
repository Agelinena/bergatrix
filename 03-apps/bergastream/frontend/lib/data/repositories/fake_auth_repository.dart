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

  @override
  Future<String> discoverServer(String server) async {
    _checkServer(server);
    return server;
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

  @override
  Future<bool> canRegister(String server) async => false;

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
