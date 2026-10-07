import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// Acesso ao `connectivity_plus` que não derruba o app quando a plataforma
/// não informa a rede. No Linux ele usa o NetworkManager pelo D-Bus do
/// sistema; sem esse barramento (contêiner, distro sem NetworkManager) a
/// exceção escapava fora de qualquer `try`. Nesse caso supomos que há rede.
abstract final class SafeConnectivity {
  static bool get supported {
    if (kIsWeb || !Platform.isLinux) return true;
    final address = Platform.environment['DBUS_SYSTEM_BUS_ADDRESS'];
    if (address != null && address.isNotEmpty) return true;
    return File('/var/run/dbus/system_bus_socket').existsSync() ||
        File('/run/dbus/system_bus_socket').existsSync();
  }

  /// Tipos de conexão atuais; sem suporte, "ethernet" (rede presente).
  static Future<List<ConnectivityResult>> current() async {
    if (!supported) return const [ConnectivityResult.ethernet];
    try {
      return await Connectivity().checkConnectivity();
    } on Object {
      return const [ConnectivityResult.ethernet];
    }
  }

  /// Avisa quando a rede muda; sem suporte, nunca avisa.
  static Stream<void> changes() {
    if (!supported) return const Stream.empty();
    return Connectivity().onConnectivityChanged
        .map((_) {})
        .handleError((Object _) {});
  }
}
