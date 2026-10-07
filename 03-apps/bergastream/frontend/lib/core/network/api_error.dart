import 'package:dio/dio.dart';

/// Tipos de erro de rede, com mensagens claras em português.
enum ApiErrorKind {
  semConexao('Não foi possível conectar. Verifique sua internet.'),
  tempoEsgotado('O servidor demorou para responder. Tente de novo.'),
  naoAutorizado('Sessão expirada. Entre de novo.'),
  naoEncontrado('Não encontrado.'),
  muitasTentativas(
    'Muitas tentativas. Aguarde alguns minutos e tente de novo.',
  ),
  servidor('O servidor teve um problema. Tente de novo em instantes.'),
  requisicao('Não foi possível concluir a ação.');

  const ApiErrorKind(this.message);

  final String message;
}

class ApiException implements Exception {
  const ApiException(this.kind, {this.statusCode});

  final ApiErrorKind kind;
  final int? statusCode;

  String get message => kind.message;

  /// Converte erros do `dio` (rede, 401, 4xx, 5xx, tempo esgotado).
  factory ApiException.fromDio(DioException e) {
    final status = e.response?.statusCode;
    final kind = switch (e.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout => ApiErrorKind.tempoEsgotado,
      DioExceptionType.connectionError => ApiErrorKind.semConexao,
      DioExceptionType.badResponse => switch (status) {
        401 => ApiErrorKind.naoAutorizado,
        404 => ApiErrorKind.naoEncontrado,
        429 => ApiErrorKind.muitasTentativas,
        final s? when s >= 500 => ApiErrorKind.servidor,
        _ => ApiErrorKind.requisicao,
      },
      _ => ApiErrorKind.semConexao,
    };
    return ApiException(kind, statusCode: status);
  }

  /// Erro de conexão em que o endereço do servidor não existe (DNS).
  static bool isHostNotFound(DioException e) {
    final text = '${e.error ?? ''} ${e.message ?? ''}'.toLowerCase();
    return text.contains('host lookup') ||
        text.contains('name or service not known') ||
        text.contains('nodename nor servname');
  }

  @override
  String toString() => 'ApiException($kind, $statusCode)';
}
