import 'package:dio/dio.dart';

/// Maps HTTP/network errors to user-friendly Portuguese messages.
String friendlyError(
  Object error, {
  String fallback = 'Algo deu errado. Tente novamente.',
}) {
  if (error is DioException) {
    final detail = _extractDetail(error);
    if (detail != null) return detail;

    return switch (error.response?.statusCode) {
      400 => 'Requisição inválida.',
      401 => 'Sessão expirada. Faça login novamente.',
      403 => 'Você não tem permissão para isso.',
      404 => 'Recurso não encontrado.',
      409 => 'Este item já existe.',
      422 => 'Dados inválidos. Verifique os campos.',
      429 => 'Muitas tentativas. Aguarde um momento.',
      500 => 'Erro interno do servidor. Tente mais tarde.',
      503 => 'Serviço indisponível no momento.',
      _ => _connectionError(error) ?? fallback,
    };
  }
  return fallback;
}

String? _extractDetail(DioException e) {
  try {
    final data = e.response?.data;
    if (data is Map) {
      final detail = data['detail'];
      if (detail is String && detail.isNotEmpty) return detail;
      if (detail is List && detail.isNotEmpty) {
        // FastAPI validation error list: [{loc, msg, type}]
        final first = detail.first;
        if (first is Map) {
          final msg = first['msg'];
          if (msg is String && msg.isNotEmpty) return msg;
        }
      }
    }
  } catch (_) {}
  return null;
}

String? _connectionError(DioException e) {
  return switch (e.type) {
    DioExceptionType.connectionTimeout ||
    DioExceptionType.sendTimeout ||
    DioExceptionType.receiveTimeout =>
      'Tempo limite de conexão esgotado.',
    DioExceptionType.connectionError => 'Sem conexão com o servidor.',
    _ => null,
  };
}
