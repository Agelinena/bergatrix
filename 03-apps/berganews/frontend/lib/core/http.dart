import 'package:dio/dio.dart';

/// `dio` com tempos limite padrão. [baseUrl] é o endereço do servidor.
Dio createDio({String baseUrl = ''}) {
  return Dio(
    BaseOptions(
      baseUrl: baseUrl,
      connectTimeout: const Duration(seconds: 10),
      sendTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 40),
      responseType: ResponseType.json,
    ),
  );
}

/// Coloca o access token em toda chamada e, num 401, renova uma vez e
/// repete. Chamadas ao mesmo tempo dividem a mesma renovação (quem garante é
/// [refresh], ver `SessionController.refreshTokens`).
class AuthInterceptor extends Interceptor {
  AuthInterceptor({
    required this.dio,
    required this.accessToken,
    required this.refresh,
  });

  final Dio dio;
  final String? Function() accessToken;
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

/// Mensagem para a pessoa: o `detail` do servidor ou o tipo da falha.
String describeError(Object error) {
  if (error is DioException) {
    final data = error.response?.data;
    if (data is Map && data['detail'] is String) return data['detail'] as String;
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.sendTimeout:
        return 'O servidor demorou para responder.';
      case DioExceptionType.connectionError:
        return 'Sem conexão com o servidor.';
      default:
        final code = error.response?.statusCode;
        if (code == 401) return 'Sessão expirada. Entre de novo.';
        if (code != null) return 'O servidor respondeu $code.';
        return 'Falha de rede.';
    }
  }
  return error.toString();
}

/// Coloca `https://` quando falta e tira a barra final; nulo se não parecer
/// um endereço.
String? normalizeServer(String input) {
  var value = input.trim();
  if (value.isEmpty) return null;
  if (!value.contains('://')) value = 'https://$value';
  while (value.endsWith('/')) {
    value = value.substring(0, value.length - 1);
  }
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.host.isEmpty ||
      !uri.isScheme('http') && !uri.isScheme('https')) {
    return null;
  }
  return value;
}

/// Endereço do servidor na web: o próprio domínio do app.
String? webServerAddress() {
  final base = Uri.base;
  if (base.isScheme('http') || base.isScheme('https')) return base.origin;
  return null;
}

/// Caminho do servidor (`/api/img?...`) → endereço completo.
String absoluteUrl(String server, String pathOrUrl) =>
    pathOrUrl.startsWith('/') ? '$server$pathOrUrl' : pathOrUrl;
