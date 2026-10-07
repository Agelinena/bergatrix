import 'package:flutter/material.dart';

import '../theme/berga_colors.dart';
import '../theme/berga_sizes.dart';
import '../theme/berga_text.dart';
import 'buttons.dart';

/// Pergunta com opções em chips (a última é a principal, em laranja).
/// [detail] aparece abaixo da pergunta, em texto secundário.
/// Devolve o índice escolhido, ou nulo se fechar sem escolher.
Future<int?> showChoiceDialog(
  BuildContext context, {
  required String message,
  required List<String> options,
  String? detail,
}) {
  final c = BergaColors.of(context);
  return showDialog<int>(
    context: context,
    barrierColor: c.scrim,
    builder: (context) => Dialog(
      backgroundColor: c.card,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(BergaSizes.cardRadius),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(message, style: BergaText.trackTitle.copyWith(color: c.tx)),
              if (detail != null && detail.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  detail,
                  maxLines: 8,
                  overflow: TextOverflow.ellipsis,
                  style: BergaText.secondary.copyWith(color: c.mu),
                ),
              ],
              const SizedBox(height: 18),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: BergaSizes.chipGap,
                runSpacing: 8,
                children: [
                  for (final (i, option) in options.indexed)
                    AppChip(
                      label: option,
                      active: i == options.length - 1,
                      onTap: () => Navigator.of(context).pop(i),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
