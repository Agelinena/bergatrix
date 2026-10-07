import 'package:flutter/material.dart';

import '../theme/berga_colors.dart';

/// Estados de download de uma faixa no aparelho (Seção 8.2).
enum DownloadState { naoBaixada, naFila, baixando, baixada, falhou }

/// Ícone pequeno do estado de download. Não mostra nada para [DownloadState.naoBaixada].
class DownloadStateIcon extends StatelessWidget {
  const DownloadStateIcon({
    super.key,
    required this.state,
    this.progress,
    this.size = 18,
  });

  final DownloadState state;

  /// Progresso de 0 a 1 em [DownloadState.baixando]; nulo = indeterminado.
  final double? progress;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = BergaColors.of(context);
    return switch (state) {
      DownloadState.naoBaixada => const SizedBox.shrink(),
      DownloadState.naFila => Icon(Icons.schedule, size: size, color: c.mu),
      DownloadState.baixando => SizedBox.square(
        dimension: size - 2,
        child: CircularProgressIndicator(
          value: progress,
          strokeWidth: 2,
          color: c.gr,
          backgroundColor: c.track,
        ),
      ),
      DownloadState.baixada => Icon(
        Icons.download_done,
        size: size,
        color: c.gr,
      ),
      DownloadState.falhou => Icon(
        Icons.error_outline,
        size: size,
        color: c.mu,
      ),
    };
  }
}
