import 'package:flutter/material.dart';

/// Tokens de cor da Seção 5.1. Acesso: `BergaColors.of(context)`.
@immutable
class BergaColors extends ThemeExtension<BergaColors> {
  const BergaColors({
    required this.bg,
    required this.card,
    required this.tx,
    required this.mu,
    required this.ac,
    required this.gr,
    required this.on,
  });

  /// Fundo da tela.
  final Color bg;

  /// Cartões, campos, mini player e folhas.
  final Color card;

  /// Texto principal.
  final Color tx;

  /// Texto secundário.
  final Color mu;

  /// Laranja: o que você toca/aciona.
  final Color ac;

  /// Verde: o que está ativo/acontecendo.
  final Color gr;

  /// Texto sobre laranja/verde.
  final Color on;

  /// Fundo das folhas inferiores (preto a 60%).
  Color get scrim => const Color(0x99000000);

  /// Trilho das barras de progresso (cinza a ~27%).
  Color get track => const Color(0x44888888);

  static const dark = BergaColors(
    bg: Color(0xFF0B0B0A),
    card: Color(0xFF191917),
    tx: Color(0xFFF2F1EC),
    mu: Color(0xFF8E8D84),
    ac: Color(0xFFFF7A1A),
    gr: Color(0xFF3FCF6E),
    on: Color(0xFF1A0B00),
  );

  static const light = BergaColors(
    bg: Color(0xFFF5F4EF),
    card: Color(0xFFE8E6DC),
    tx: Color(0xFF14130F),
    mu: Color(0xFF6A685C),
    ac: Color(0xFFD95F00),
    gr: Color(0xFF1F9A4A),
    on: Color(0xFFFFFFFF),
  );

  static BergaColors of(BuildContext context) =>
      Theme.of(context).extension<BergaColors>()!;

  @override
  BergaColors copyWith({
    Color? bg,
    Color? card,
    Color? tx,
    Color? mu,
    Color? ac,
    Color? gr,
    Color? on,
  }) {
    return BergaColors(
      bg: bg ?? this.bg,
      card: card ?? this.card,
      tx: tx ?? this.tx,
      mu: mu ?? this.mu,
      ac: ac ?? this.ac,
      gr: gr ?? this.gr,
      on: on ?? this.on,
    );
  }

  @override
  BergaColors lerp(BergaColors? other, double t) {
    if (other == null) return this;
    return BergaColors(
      bg: Color.lerp(bg, other.bg, t)!,
      card: Color.lerp(card, other.card, t)!,
      tx: Color.lerp(tx, other.tx, t)!,
      mu: Color.lerp(mu, other.mu, t)!,
      ac: Color.lerp(ac, other.ac, t)!,
      gr: Color.lerp(gr, other.gr, t)!,
      on: Color.lerp(on, other.on, t)!,
    );
  }
}
