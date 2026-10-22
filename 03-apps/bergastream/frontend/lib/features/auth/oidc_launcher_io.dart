import 'dart:async';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:url_launcher/url_launcher.dart';

import 'oidc_launcher.dart';

OidcLauncher createOidcLauncher() => Platform.isAndroid || Platform.isIOS
    ? _AppLinkLauncher()
    : _LoopbackLauncher();

const _timeout = Duration(minutes: 5);

/// Android: o Authentik volta para `com.bergatrix.bergastream://auth`.
class _AppLinkLauncher implements OidcLauncher {
  static const scheme = 'com.bergatrix.bergastream';
  final _links = AppLinks();

  static String? _codeOf(Uri? uri) => uri != null && uri.scheme == scheme
      ? uri.queryParameters['oidc_code']
      : null;

  @override
  Future<String> redirect() async => '$scheme://auth';

  @override
  Future<String?> open(Uri url) async {
    final code = _links.uriLinkStream
        .map(_codeOf)
        .where((c) => c != null)
        .first
        .timeout(_timeout, onTimeout: () => null);
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      return null;
    }
    return code;
  }

  @override
  Future<String?> initialCode() async {
    try {
      return _codeOf(await _links.getInitialLink());
    } on Object {
      return null;
    }
  }

  @override
  void clearInitialCode() {}

  @override
  Future<void> cancel() async {}
}

/// Windows/Linux: o app escuta um endereço local (RFC 8252) e o Authentik
/// volta para ele; a página diz que já pode voltar ao app.
class _LoopbackLauncher implements OidcLauncher {
  HttpServer? _server;

  @override
  Future<String> redirect() async {
    await cancel();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    return 'http://127.0.0.1:${server.port}/callback';
  }

  @override
  Future<String?> open(Uri url) async {
    final server = _server;
    if (server == null) return null;
    final code = Completer<String?>();
    final sub = server.listen((request) async {
      if (request.uri.path != '/callback') {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final value = request.uri.queryParameters['oidc_code'];
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.html
        ..write(
          '<!doctype html><meta charset="utf-8"><title>Bergastream</title>'
          '<body style="font-family:system-ui;background:#111;color:#eee;'
          'display:grid;place-items:center;min-height:100vh;margin:0">'
          '<main style="text-align:center"><h1>Pronto!</h1>'
          '<p>Pode fechar esta aba e voltar ao Bergastream.</p></main>',
        );
      await request.response.close();
      if (!code.isCompleted) code.complete(value);
    });
    try {
      if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
        return null;
      }
      return await code.future.timeout(_timeout, onTimeout: () => null);
    } finally {
      await sub.cancel();
      await cancel();
    }
  }

  @override
  Future<String?> initialCode() async => null;

  @override
  void clearInitialCode() {}

  @override
  Future<void> cancel() async {
    await _server?.close(force: true);
    _server = null;
  }
}
