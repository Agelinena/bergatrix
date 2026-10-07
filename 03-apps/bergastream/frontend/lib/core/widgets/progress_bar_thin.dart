import 'package:flutter/material.dart';

import '../theme/berga_colors.dart';
import '../theme/berga_sizes.dart';

/// Barra de progresso fina: trilho cinza, preenchimento verde.
/// Altura 3 no mini player e 5 no player grande.
class ProgressBarThin extends StatelessWidget {
  const ProgressBarThin({
    super.key,
    required this.value,
    this.height = BergaSizes.progressHeight,
  });

  /// De 0 a 1.
  final double value;
  final double height;

  @override
  Widget build(BuildContext context) {
    final c = BergaColors.of(context);
    final radius = BorderRadius.circular(9);
    return Container(
      height: height,
      decoration: BoxDecoration(color: c.track, borderRadius: radius),
      alignment: Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: value.clamp(0.0, 1.0),
        child: DecoratedBox(
          decoration: BoxDecoration(color: c.gr, borderRadius: radius),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}
