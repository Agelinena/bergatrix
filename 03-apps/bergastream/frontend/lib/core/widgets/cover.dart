import 'package:flutter/material.dart';

import '../theme/berga_sizes.dart';

/// Capa quadrada (ou circular). Sem imagem, desenha o gradiente de 135° com a
/// inicial do título (Seção 5.3).
class Cover extends StatelessWidget {
  const Cover({
    super.key,
    required this.seed,
    required this.title,
    required this.size,
    this.radius = BergaSizes.coverRadius,
    this.circle = false,
    this.initialSize,
    this.image,
  }) : _playlist = false;

  /// Capa de playlist sem foto: gradiente laranja → verde com o ícone de nota
  /// (o caractere ♫ não existe na Bricolage Grotesque).
  const Cover.playlist({
    super.key,
    required this.size,
    this.radius = BergaSizes.coverRadius,
    this.initialSize,
    this.image,
  }) : seed = '',
       title = '',
       circle = false,
       _playlist = true;

  /// Define a cor (normalmente o id da faixa, artista ou álbum).
  final String seed;
  final String title;
  final double size;
  final double radius;
  final bool circle;

  /// Tamanho da inicial; padrão ~40% da capa.
  final double? initialSize;
  final ImageProvider? image;
  final bool _playlist;

  static const minHue = 18;
  static const maxHue = 150;

  /// Matiz derivado de [seed], sempre entre [minHue] e [maxHue]
  /// (laranja → âmbar → verde). Usa FNV-1a para ser igual em todas as
  /// plataformas (o `hashCode` de String muda entre web e nativo).
  static int hueFor(String seed) {
    var hash = 0x811c9dc5;
    for (final unit in seed.codeUnits) {
      hash ^= unit;
      // hash * 0x01000193 (2^24 + 0x193) em 32 bits, sem passar de 2^53:
      // na web os inteiros são doubles e perderiam precisão.
      hash = (((hash & 0xff) << 24) + hash * 0x193) & 0xffffffff;
    }
    return minHue + hash % (maxHue - minHue + 1);
  }

  /// Primeiro caractere visível do título; nulo se o título estiver vazio
  /// (aí a capa mostra o ícone de nota).
  static String? initialOf(String title) {
    final trimmed = title.trim();
    return trimmed.isEmpty ? null : trimmed.characters.first;
  }

  static LinearGradient gradientFor(String seed) {
    final hue = hueFor(seed).toDouble();
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        HSLColor.fromAHSL(1, hue, 0.65, 0.52).toColor(),
        HSLColor.fromAHSL(1, hue + 25, 0.60, 0.30).toColor(),
      ],
    );
  }

  static final _playlistGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      const HSLColor.fromAHSL(1, 24, 0.85, 0.50).toColor(),
      const HSLColor.fromAHSL(1, 140, 0.60, 0.28).toColor(),
    ],
  );

  static const _shadow = Shadow(
    offset: Offset(0, 1),
    blurRadius: 3,
    color: Color(0x66000000),
  );

  @override
  Widget build(BuildContext context) {
    final glyphSize = initialSize ?? size * 0.4;
    final initial = _playlist ? null : initialOf(title);
    return SizedBox(
      width: size,
      height: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: circle ? BoxShape.circle : BoxShape.rectangle,
          borderRadius: circle ? null : BorderRadius.circular(radius),
          gradient: _playlist ? _playlistGradient : gradientFor(seed),
          image: image == null
              ? null
              : DecorationImage(image: image!, fit: BoxFit.cover),
        ),
        child: image != null
            ? null
            : Center(
                child: initial == null
                    ? Icon(
                        Icons.music_note,
                        size: glyphSize,
                        color: Colors.white,
                        shadows: const [_shadow],
                      )
                    : Text(
                        initial,
                        style: TextStyle(
                          fontSize: glyphSize,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                          height: 1,
                          shadows: const [_shadow],
                        ),
                      ),
              ),
      ),
    );
  }
}
