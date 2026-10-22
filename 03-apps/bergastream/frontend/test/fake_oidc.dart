import 'package:bergastream/features/auth/oidc_launcher.dart';

/// "Navegador" do login pelo Authentik: devolve [code] (nulo = desistiu) e
/// guarda o endereço aberto.
class FakeOidcLauncher implements OidcLauncher {
  FakeOidcLauncher({this.code, this.initial});

  String? code;

  /// Código no endereço de abertura (web recarregada, Android reaberto).
  String? initial;
  final opened = <Uri>[];
  var cancelled = 0;

  @override
  Future<String> redirect() async => 'http://127.0.0.1:5000/callback';

  @override
  Future<String?> open(Uri url) async {
    opened.add(url);
    return code;
  }

  @override
  Future<String?> initialCode() async => initial;

  @override
  void clearInitialCode() => initial = null;

  @override
  Future<void> cancel() async => cancelled++;
}
