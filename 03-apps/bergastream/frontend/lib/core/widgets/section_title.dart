import 'package:flutter/material.dart';

import '../theme/berga_colors.dart';
import '../theme/berga_sizes.dart';
import '../theme/berga_text.dart';

/// Título de seção (`h2`).
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(
        top: BergaSizes.h2Top,
        bottom: BergaSizes.h2Bottom,
      ),
      child: Text(
        text,
        style: BergaText.h2.copyWith(color: BergaColors.of(context).tx),
      ),
    );
  }
}

/// Título de tela (`h1`).
class ScreenTitle extends StatelessWidget {
  const ScreenTitle(this.text, {super.key, this.bottom = BergaSizes.h1Bottom});

  final String text;
  final double bottom;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: Text(
        text,
        style: BergaText.h1.copyWith(color: BergaColors.of(context).tx),
      ),
    );
  }
}
