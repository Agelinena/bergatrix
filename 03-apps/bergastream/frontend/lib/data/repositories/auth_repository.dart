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

  /// Como o servidor aceita o login (Authentik, senha, cadastro). Nulo se
  /// não respondeu (aí não dá para saber: a tela mostra as duas formas).
  Future<AuthOptions?> options(String server);

  /// "Esqueci minha senha": o servidor manda o link para o e-mail da conta
  /// ([login] = usuário ou e-mail). Não diz se a conta existe.
  Future<void> forgotPassword({required String server, required String login});

  /// Troca o código de uso único do login pelo Authentik pelos tokens do
  /// Bergastream, provando o PKCE do app ([verifier]).
  Future<TokenResponse> exchangeOidc({
    required String server,
    required String code,
    required String verifier,
  });
}

/// Caminho do Traefik que libera a API para os apps (sem Authentik).
const bypassPrefix = '/api-access-bypass';

/// Endereços a testar, em ordem: o endereço simples primeiro (com o login
/// pelo Authentik dentro do app, o servidor tem uma rota só); o bypass é
/// para servidores ainda atrás do forward-auth do Authentik.
List<String> serverCandidates(String server) {
  final uri = Uri.parse(server);
  // Endereço salvo pela 0.3.x (com o caminho antigo): o simples primeiro.
  if (uri.path == bypassPrefix) {
    return [server.substring(0, server.length - bypassPrefix.length), server];
  }
  if (uri.path.isNotEmpty && uri.path != '/') return [server];
  return [server, '$server$bypassPrefix'];
}

final authRepositoryProvider = Provider<AuthRepository>(HttpAuthRepository.new);
