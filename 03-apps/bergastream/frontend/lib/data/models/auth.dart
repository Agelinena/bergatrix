import 'package:json_annotation/json_annotation.dart';

part 'auth.g.dart';

/// Tokens de acesso devolvidos pelo servidor.
class AuthTokens {
  const AuthTokens({required this.accessToken, required this.refreshToken});

  final String accessToken;
  final String refreshToken;
}

/// Usuário conectado (`/api/auth/me` e resposta do login).
@JsonSerializable(fieldRename: FieldRename.snake)
class AuthUser {
  const AuthUser({
    required this.id,
    required this.username,
    required this.name,
    this.isAdmin = false,
  });

  factory AuthUser.fromJson(Map<String, dynamic> json) =>
      _$AuthUserFromJson(json);

  final String id;
  final String username;
  final String name;
  final bool isAdmin;

  Map<String, dynamic> toJson() => _$AuthUserToJson(this);
}

/// Resposta de `/api/auth/login`, `/register` e `/refresh`.
@JsonSerializable(fieldRename: FieldRename.snake, createToJson: false)
class TokenResponse {
  const TokenResponse({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresIn,
    required this.user,
  });

  factory TokenResponse.fromJson(Map<String, dynamic> json) =>
      _$TokenResponseFromJson(json);

  final String accessToken;
  final String refreshToken;
  final int expiresIn;
  final AuthUser user;

  AuthTokens get tokens =>
      AuthTokens(accessToken: accessToken, refreshToken: refreshToken);
}

/// Erros de login mostrados na tela (Seção 2.2).
enum AuthError {
  /// "Servidor não encontrado. Confira o endereço."
  servidorNaoEncontrado,

  /// "Usuário ou senha incorretos."
  credenciaisInvalidas,

  /// "Não foi possível conectar. Verifique sua internet."
  semConexao,

  /// "Muitas tentativas. Aguarde alguns minutos e tente de novo."
  muitasTentativas,
}

class AuthException implements Exception {
  const AuthException(this.error);

  final AuthError error;

  @override
  String toString() => 'AuthException($error)';
}
