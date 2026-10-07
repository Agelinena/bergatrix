import 'package:dio/dio.dart';

/// `dio` com tempos limite padrão. [baseUrl] é o endereço do servidor.
Dio createDio({String baseUrl = ''}) {
  return Dio(
    BaseOptions(
      baseUrl: baseUrl,
      connectTimeout: const Duration(seconds: 10),
      sendTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      responseType: ResponseType.json,
    ),
  );
}

/// Coloca o access token em toda chamada e, num 401, renova o token uma vez
/// e repete a chamada. Chamadas concorrentes compartilham a mesma renovação
/// (quem garante é [refresh], ver `SessionController.refreshTokens`).
class AuthInterceptor extends Interceptor {
  AuthInterceptor({
    required this.dio,
    required this.accessToken,
    required this.refresh,
  });

  final Dio dio;
  final String? Function() accessToken;

  /// Renova os tokens; devolve se deu certo.
  final Future<bool> Function() refresh;

  static const _retried = 'auth_retried';

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final token = accessToken();
    if (token != null) options.headers['Authorization'] = 'Bearer $token';
    handler.next(options);
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final options = err.requestOptions;
    if (err.response?.statusCode != 401 || options.extra[_retried] == true) {
      return handler.next(err);
    }
    // Se outra chamada já renovou enquanto esta estava no ar, só repete.
    final sentWith = options.headers['Authorization'];
    final current = accessToken();
    final renewed =
        current != null && sentWith != 'Bearer $current' || await refresh();
    if (!renewed) return handler.next(err);

    final retry = options.copyWith(
      headers: {...options.headers, 'Authorization': 'Bearer ${accessToken()}'},
      extra: {...options.extra, _retried: true},
    );
    try {
      handler.resolve(await dio.fetch<dynamic>(retry));
    } on DioException catch (e) {
      handler.next(e);
    }
  }
}
