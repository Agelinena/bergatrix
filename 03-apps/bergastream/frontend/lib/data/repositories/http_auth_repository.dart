import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_error.dart';
import '../api/api_dio.dart';
import '../models/auth.dart';
import 'auth_repository.dart';

/// Implementação real de [AuthRepository]. Login, renovação e logout usam um
/// `dio` sem o interceptor de token (não faz sentido renovar o token para
/// renovar o token); `me` usa o cliente autenticado.
class HttpAuthRepository implements AuthRepository {
  HttpAuthRepository(this._ref, [Dio? dio]) : _dio = dio ?? createDio();

  final Ref _ref;
  final Dio _dio;

  @override
  Future<TokenResponse> login({
    required String server,
    required String username,
    required String password,
  }) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '$server/api/auth/login',
        data: {'username': username, 'password': password},
      );
      return TokenResponse.fromJson(response.data!);
    } on DioException catch (e) {
      throw AuthException(_loginError(e));
    } on Object {
      // Respondeu, mas não é um servidor Bergastream (JSON inesperado).
      throw const AuthException(AuthError.servidorNaoEncontrado);
    }
  }

  @override
  Future<AuthTokens> refresh({
    required String server,
    required String refreshToken,
  }) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '$server/api/auth/refresh',
        data: {'refresh_token': refreshToken},
      );
      return TokenResponse.fromJson(response.data!).tokens;
    } on DioException catch (e) {
      throw AuthException(_loginError(e));
    }
  }

  @override
  Future<void> logout({
    required String server,
    required String refreshToken,
  }) async {
    try {
      await _dio.post<void>(
        '$server/api/auth/logout',
        data: {'refresh_token': refreshToken},
      );
    } on DioException {
      // Sem rede o token expira sozinho; sair funciona do mesmo jeito.
    }
  }

  @override
  Future<AuthUser> me() async {
    try {
      final response = await _ref
          .read(apiDioProvider)
          .get<Map<String, dynamic>>('/api/auth/me');
      return AuthUser.fromJson(response.data!);
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }

  @override
  Future<String> discoverServer(String server) async {
    var error = AuthError.servidorNaoEncontrado;
    for (final candidate in serverCandidates(server)) {
      try {
        final response = await _dio.get<Map<String, dynamic>>(
          '$candidate/api/auth/config',
        );
        if (response.data?.containsKey('registration_enabled') ?? false) {
          return candidate;
        }
      } on DioException catch (e) {
        // Sem conexão vale mais que "não encontrado" (é o que a pessoa
        // precisa resolver). Resposta inválida (HTML, 404) é "não encontrado".
        const network = {
          DioExceptionType.connectionError,
          DioExceptionType.connectionTimeout,
          DioExceptionType.receiveTimeout,
          DioExceptionType.sendTimeout,
        };
        if (network.contains(e.type) && !ApiException.isHostNotFound(e)) {
          error = AuthError.semConexao;
        }
      } on Object {
        // Respondeu outra coisa (página de login do Authentik, outro site).
      }
    }
    throw AuthException(error);
  }

  @override
  Future<bool> canRegister(String server) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '$server/api/auth/config',
      );
      return response.data?['registration_enabled'] == true;
    } on Object {
      return false;
    }
  }

  static AuthError _loginError(DioException e) {
    final status = e.response?.statusCode;
    // 400/422: campos vazios ou inválidos (o backend valida o formato).
    if (const {400, 401, 403, 422}.contains(status)) {
      return AuthError.credenciaisInvalidas;
    }
    if (status == 429) return AuthError.muitasTentativas;
    if (status == 404) return AuthError.servidorNaoEncontrado;
    // Respondeu algo que não é JSON (página de outro site): não é Bergastream.
    if (e.error is FormatException) return AuthError.servidorNaoEncontrado;
    if (e.type == DioExceptionType.connectionError &&
        ApiException.isHostNotFound(e)) {
      return AuthError.servidorNaoEncontrado;
    }
    return AuthError.semConexao;
  }
}
