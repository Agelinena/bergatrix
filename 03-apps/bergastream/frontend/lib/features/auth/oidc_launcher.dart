import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'oidc_launcher_io.dart'
    if (dart.library.js_interop) 'oidc_launcher_web.dart'
    as platform;

/// Abre o login do Authentik no navegador e devolve o código de uso único
/// que o servidor do Bergastream mandou de volta (ver
/// `backend/app/auth/oidc.py`).
///
/// - Web: a própria página vai ao Authentik e volta com `?oidc_code=`
///   ([open] não retorna; o login termina ao abrir de novo, por
///   [initialCode]).
/// - Android: volta pelo link `com.bergatrix.bergastream://auth`.
/// - Windows/Linux: volta por um endereço local (127.0.0.1) que o app escuta.
abstract interface class OidcLauncher {
  /// Para onde o servidor devolve o app.
  Future<String> redirect();

  /// Abre [url] (o /api/auth/oidc/start) e espera o código; nulo se a pessoa
  /// desistiu ou demorou demais.
  Future<String?> open(Uri url);

  /// Código que chegou ao abrir o app (web: na URL; Android: link que
  /// reabriu o app depois de o sistema fechá-lo).
  Future<String?> initialCode();

  /// Tira o código da barra de endereço (web).
  void clearInitialCode();

  /// Libera o que ficou aberto (servidor local).
  Future<void> cancel();
}

final oidcLauncherProvider = Provider<OidcLauncher>(
  (ref) => platform.createOidcLauncher(),
);
