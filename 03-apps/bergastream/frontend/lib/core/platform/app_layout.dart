import 'package:flutter/widgets.dart';

import '../theme/berga_sizes.dart';
import 'app_platform.dart';

/// Layout em uso: celular (Seções 6.1–6.6) ou navegador/desktop (Seção 6.8).
enum LayoutKind { mobile, desktop }

/// Disponibiliza o layout para as telas, que ajustam o padding.
class AppLayout extends InheritedWidget {
  const AppLayout({super.key, required this.kind, required super.child});

  final LayoutKind kind;

  /// Largura a partir da qual a web e o app de Windows/Linux usam o layout
  /// de navegador.
  static const desktopFrom = 900.0;

  static LayoutKind kindFor(AppPlatform platform, double width) {
    final wideCapable = platform.isWeb || platform.isDesktop;
    if (wideCapable && width >= desktopFrom) return LayoutKind.desktop;
    return LayoutKind.mobile;
  }

  static LayoutKind of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppLayout>()?.kind ??
      LayoutKind.mobile;

  static bool isDesktop(BuildContext context) =>
      of(context) == LayoutKind.desktop;

  /// Padding das telas: o do celular deixa espaço para mini player e
  /// navegação; no navegador o player fica fora da área de conteúdo.
  static EdgeInsets screenPadding(BuildContext context) => isDesktop(context)
      ? const EdgeInsets.fromLTRB(32, 24, 32, 40)
      : BergaSizes.screenPadding;

  @override
  bool updateShouldNotify(AppLayout oldWidget) => kind != oldWidget.kind;
}
