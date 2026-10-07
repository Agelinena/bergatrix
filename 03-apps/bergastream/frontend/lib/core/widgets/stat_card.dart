import 'package:flutter/material.dart';

import '../theme/berga_colors.dart';
import '../theme/berga_sizes.dart';
import '../theme/berga_text.dart';

/// Cartão de métrica da tela inicial: número grande em verde e legenda.
class StatCard extends StatelessWidget {
  const StatCard({super.key, required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final c = BergaColors.of(context);
    return Container(
      padding: const EdgeInsets.all(BergaSizes.cardPadding),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(BergaSizes.cardRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: BergaText.statNumber.copyWith(color: c.gr)),
          Text(label, style: BergaText.secondary.copyWith(color: c.mu)),
        ],
      ),
    );
  }
}

/// Cartão genérico (raio 14, padding 14, fundo `card`, margem superior 10).
class AppCard extends StatelessWidget {
  const AppCard({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: BergaSizes.cardMarginTop),
      padding: const EdgeInsets.all(BergaSizes.cardPadding),
      decoration: BoxDecoration(
        color: BergaColors.of(context).card,
        borderRadius: BorderRadius.circular(BergaSizes.cardRadius),
      ),
      child: child,
    );
  }
}
