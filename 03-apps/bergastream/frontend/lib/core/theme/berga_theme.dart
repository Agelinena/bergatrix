import 'package:flutter/material.dart';

import 'berga_colors.dart';
import 'berga_text.dart';

/// Monta o [ThemeData] a partir dos tokens. O protótipo não tem efeito de
/// toque (ripple), então ele fica desligado.
abstract final class BergaTheme {
  static ThemeData get dark => _build(BergaColors.dark, Brightness.dark);
  static ThemeData get light => _build(BergaColors.light, Brightness.light);

  static ThemeData _build(BergaColors c, Brightness brightness) {
    final body = BergaText.body.copyWith(color: c.tx);
    return ThemeData(
      brightness: brightness,
      fontFamily: BergaText.fontFamily,
      scaffoldBackgroundColor: c.bg,
      canvasColor: c.bg,
      colorScheme: ColorScheme(
        brightness: brightness,
        primary: c.ac,
        onPrimary: c.on,
        secondary: c.gr,
        onSecondary: c.on,
        error: c.ac,
        onError: c.on,
        surface: c.bg,
        onSurface: c.tx,
      ),
      textTheme: TextTheme(
        bodyLarge: body,
        bodyMedium: body,
        bodySmall: BergaText.secondary.copyWith(color: c.mu),
        titleMedium: body,
        labelLarge: BergaText.button.copyWith(color: c.tx),
      ),
      iconTheme: IconThemeData(color: c.tx),
      textSelectionTheme: TextSelectionThemeData(cursorColor: c.ac),
      // O padrão no web/desktop é compacto e encolhe campos e botões; o
      // design é o mesmo em todas as plataformas.
      visualDensity: VisualDensity.standard,
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      hoverColor: Colors.transparent,
      extensions: [c],
    );
  }
}
