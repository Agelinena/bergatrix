import 'package:flutter/material.dart';

/// Tipografia da Seção 5.2. As cores são aplicadas por quem usa o estilo.
abstract final class BergaText {
  static const fontFamily = 'BricolageGrotesque';

  /// `height: 1.2` é a altura natural da Bricolage (hhea: 930 + 270 sobre
  /// 1000), a mesma do `line-height: normal` do protótipo. Fixar o valor
  /// evita herdar o 1.43 que o Material 3 põe nos estilos de texto.
  static const _base = TextStyle(
    fontFamily: fontFamily,
    letterSpacing: 0,
    height: 1.2,
  );

  /// Título de tela.
  static final h1 = _base.copyWith(fontSize: 28, fontWeight: FontWeight.w800);

  /// Título de seção.
  static final h2 = _base.copyWith(fontSize: 17, fontWeight: FontWeight.w600);

  static final body = _base.copyWith(fontSize: 15, fontWeight: FontWeight.w400);

  /// Título de faixa nas linhas.
  static final trackTitle = _base.copyWith(
    fontSize: 15,
    fontWeight: FontWeight.w600,
  );

  /// Texto secundário (cor `mu`).
  static final secondary = _base.copyWith(
    fontSize: 13,
    fontWeight: FontWeight.w400,
  );

  static final chip = _base.copyWith(fontSize: 13, fontWeight: FontWeight.w400);

  static final chipActive = _base.copyWith(
    fontSize: 13,
    fontWeight: FontWeight.w600,
  );

  static final button = _base.copyWith(
    fontSize: 15,
    fontWeight: FontWeight.w600,
  );

  static final navLabel = _base.copyWith(
    fontSize: 12,
    fontWeight: FontWeight.w400,
  );

  /// Número grande das métricas.
  static final statNumber = _base.copyWith(
    fontSize: 26,
    fontWeight: FontWeight.w800,
  );

  /// Texto do aviso rápido.
  static final toast = _base.copyWith(
    fontSize: 13,
    fontWeight: FontWeight.w600,
  );
}
