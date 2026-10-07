import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../features/auth/session.dart';
import '../../features/sync/server_monitor.dart';

/// Cliente autenticado para o servidor da sessão atual. Recriado quando o
/// endereço do servidor muda.
final apiDioProvider = Provider<Dio>((ref) {
  final server = ref.watch(sessionProvider.select((s) => s.server)) ?? '';
  final dio = createDio(baseUrl: server);
  final session = ref.read(sessionProvider.notifier);
  dio.interceptors.add(
    AuthInterceptor(
      dio: dio,
      accessToken: () => session.accessToken,
      refresh: session.refreshTokens,
    ),
  );
  // Falha de conexão em qualquer chamada: servidor indisponível (Passo 11).
  dio.interceptors.add(
    InterceptorsWrapper(
      onError: (e, handler) {
        if (e.type == DioExceptionType.connectionError ||
            e.type == DioExceptionType.connectionTimeout) {
          ref.read(serverMonitorProvider.notifier).reportFailure();
        } else if (const {502, 503, 504}.contains(e.response?.statusCode)) {
          // Atrás de um proxy (nginx), API fora do ar vira 502/503/504:
          // confere o /health antes de marcar indisponível.
          ref.read(serverMonitorProvider.notifier).check();
        }
        handler.next(e);
      },
    ),
  );
  ref.onDispose(dio.close);
  return dio;
});
