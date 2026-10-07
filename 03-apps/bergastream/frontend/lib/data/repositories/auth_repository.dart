import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/auth.dart';
import 'http_auth_repository.dart';

/// Autenticação no servidor (`/api/auth/*`, ver `docs/API_MAP.md`).
abstract interface class AuthRepository {
  /// Lança [AuthException] em caso de erro.
  Future<TokenResponse> login({
    required String server,
    required String username,
    required String password,
  });

  /// Troca o refresh token por um par novo (o antigo deixa de valer).
  /// Lança [AuthException] se não for possível.
  Future<AuthTokens> refresh({
    required String server,
    required String refreshToken,
  });

  /// Encerra a sessão no servidor. Erros são ignorados.
  Future<void> logout({required String server, required String refreshToken});

  /// Usuário do token atual. Lança `ApiException`.
  Future<AuthUser> me();

  /// Endereço que de fato responde como Bergastream a partir do que a
  /// pessoa digitou. Atrás do Traefik (modelo B) os apps passam pelo
  /// prefixo [bypassPrefix], que não exige o login do Authentik.
  /// Lança [AuthException] se nenhum candidato responder.
  Future<String> discoverServer(String server);

  /// Se o servidor permite criar conta (mostra o link "Criar conta").
  Future<bool> canRegister(String server);
}

/// Caminho do Traefik que libera a API para os apps (sem Authentik).
const bypassPrefix = '/api-access-bypass';

/// Endereços a testar, em ordem: o bypass primeiro, porque funciona em casa
/// e fora (o endereço simples só passa direto pelos aparelhos de
/// confiança da rede local).
List<String> serverCandidates(String server) {
  final uri = Uri.parse(server);
  if (uri.path.isNotEmpty && uri.path != '/') return [server];
  return ['$server$bypassPrefix', server];
}

final authRepositoryProvider = Provider<AuthRepository>(HttpAuthRepository.new);
