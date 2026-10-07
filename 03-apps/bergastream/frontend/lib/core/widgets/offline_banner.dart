import 'package:flutter/material.dart';

import '../theme/berga_colors.dart';
import '../theme/berga_text.dart';

/// Faixa fina de aviso logo acima do conteúdo (servidor indisponível,
/// sessão expirada). Mostra um botão de texto verde quando há ação.
class OfflineBanner extends StatelessWidget {
  const OfflineBanner({
    super.key,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final c = BergaColors.of(context);
    return Container(
      width: double.infinity,
      color: c.card,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              message,
              style: BergaText.secondary.copyWith(color: c.mu),
            ),
          ),
          if (actionLabel != null)
            GestureDetector(
              onTap: onAction,
              child: Padding(
                padding: const EdgeInsets.only(left: 12),
                child: Text(
                  actionLabel!,
                  style: BergaText.chipActive.copyWith(color: c.gr),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
