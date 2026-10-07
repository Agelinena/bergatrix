import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/connectivity.dart';
import '../auth/session.dart';

/// Pergunta se o servidor responde. Usa `/api/auth/config` (pública e sob
/// `/api`, que o proxy do app web encaminha) e exige o JSON da API: `/health`
/// cairia no `index.html` do app web e sempre pareceria "no ar".
typedef ServerPing = Future<bool> Function(String server);

Future<bool> _ping(String server) async {
  try {
    final r = await Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 5),
        responseType: ResponseType.json,
      ),
    ).get<dynamic>('$server/api/auth/config');
    final body = r.data;
    return r.statusCode == 200 &&
        body is Map &&
        body.containsKey('registration_enabled');
  } on DioException {
    return false;
  }
}

final serverPingProvider = Provider<ServerPing>((ref) => _ping);

/// Intervalo das novas tentativas enquanto o servidor está fora; nulo
/// desliga a repetição (testes de tela).
final serverRetryIntervalProvider = Provider<Duration?>(
  (ref) => const Duration(seconds: 30),
);

/// Mudanças de rede (Wi-Fi, dados, sem rede).
final connectivityChangesProvider = Provider<Stream<void>>(
  (ref) => SafeConnectivity.changes(),
);

/// Detecção do servidor (Seções 2.3 e 11): marca "indisponível" quando uma
/// chamada falha por conexão; confere de novo ao mudar a rede e a cada
/// intervalo de [serverRetryIntervalProvider] enquanto estiver fora. O
/// aviso some sozinho ao voltar.
class ServerMonitor extends Notifier<void> {
  Timer? _timer;
  StreamSubscription<void>? _network;
  bool _checking = false;

  @override
  void build() {
    ref.listen(
      sessionProvider.select((s) => s.isLoggedIn && !s.serverAvailable),
      (_, down) {
        if (down && _timer == null) _schedule();
      },
    );
    ref.onDispose(() {
      _timer?.cancel();
      _network?.cancel();
    });
  }

  void start() {
    _network ??= ref.read(connectivityChangesProvider).listen((_) => check());
  }

  /// Chamada falhou por falta de conexão: considera fora e passa a conferir.
  void reportFailure() {
    final session = ref.read(sessionProvider);
    if (!session.isLoggedIn) return;
    if (session.serverAvailable) {
      ref.read(sessionProvider.notifier).setServerAvailable(false);
    }
    _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    final every = ref.read(serverRetryIntervalProvider);
    if (every == null) return;
    _timer = Timer.periodic(every, (_) => check());
  }

  /// Confere agora. Devolve se o servidor está disponível.
  Future<bool> check() async {
    final session = ref.read(sessionProvider);
    if (!session.isLoggedIn || session.server == null || _checking) {
      return session.serverAvailable;
    }
    _checking = true;
    try {
      final ok = await ref.read(serverPingProvider)(session.server!);
      if (!ref.mounted) return ok;
      if (ok != ref.read(sessionProvider).serverAvailable) {
        ref.read(sessionProvider.notifier).setServerAvailable(ok);
      }
      if (ok) {
        _timer?.cancel();
        _timer = null;
      } else if (_timer == null) {
        _schedule();
      }
      return ok;
    } finally {
      _checking = false;
    }
  }
}

final serverMonitorProvider = NotifierProvider<ServerMonitor, void>(
  ServerMonitor.new,
);
