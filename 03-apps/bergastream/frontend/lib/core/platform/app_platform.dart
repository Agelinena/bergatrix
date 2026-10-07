import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Regras de acesso da plataforma (Seção 2.1).
///
/// - **Web:** login obrigatório, sem modo local nem downloads.
/// - **App** (Android/Windows/Linux): pode usar sem login (modo local).
///   No Windows/Linux ([isDesktop]) a janela larga usa o layout de navegador.
///
/// No build web, `?modo=android` simula o app: mesmas regras do Android e
/// layout de celular. Serve para desenvolver sem compilar o APK.
class AppPlatform {
  const AppPlatform({
    required this.isWeb,
    this.simulated = false,
    this.isDesktop = false,
  });

  /// Build web normal (Seção 2.1, coluna "Web").
  const AppPlatform.web() : this(isWeb: true);

  /// App nativo (Android/Windows/Linux).
  const AppPlatform.app() : this(isWeb: false);

  /// App nativo de Windows/Linux: regras do app, layout largo na janela.
  const AppPlatform.desktop() : this(isWeb: false, isDesktop: true);

  /// Build web simulando o Android (`?modo=android`).
  const AppPlatform.simulatedAndroid() : this(isWeb: false, simulated: true);

  final bool isWeb;
  final bool simulated;
  final bool isDesktop;

  bool get isApp => !isWeb;

  static AppPlatform detect() {
    if (!kIsWeb) {
      return switch (defaultTargetPlatform) {
        TargetPlatform.linux ||
        TargetPlatform.windows ||
        TargetPlatform.macOS => const AppPlatform.desktop(),
        _ => const AppPlatform.app(),
      };
    }
    if (Uri.base.queryParameters['modo'] == 'android') {
      return const AppPlatform.simulatedAndroid();
    }
    return const AppPlatform.web();
  }
}

/// Definido em `main.dart` (e nos testes).
final appPlatformProvider = Provider<AppPlatform>(
  (ref) => throw UnimplementedError('appPlatformProvider não foi definido'),
);
