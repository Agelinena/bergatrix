import 'dart:async';

import 'package:web/web.dart' as web;

import 'oidc_launcher.dart';

OidcLauncher createOidcLauncher() => _WebLauncher();

/// Web: a página vai ao Authentik e volta para `/?oidc_code=…`.
class _WebLauncher implements OidcLauncher {
  @override
  Future<String> redirect() async => '/';

  @override
  Future<String?> open(Uri url) {
    web.window.location.assign(url.toString());
    // A página sai daqui; o login termina ao voltar (initialCode).
    return Completer<String?>().future;
  }

  @override
  Future<String?> initialCode() async => Uri.base.queryParameters['oidc_code'];

  @override
  void clearInitialCode() {
    final url = Uri.base;
    if (!url.queryParameters.containsKey('oidc_code')) return;
    final clean = url.replace(
      queryParameters: {
        for (final e in url.queryParameters.entries)
          if (e.key != 'oidc_code') e.key: e.value,
      },
    );
    var text = clean.toString();
    if (text.endsWith('?')) text = text.substring(0, text.length - 1);
    web.window.history.replaceState(null, '', text);
  }

  @override
  Future<void> cancel() async {}
}
