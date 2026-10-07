import 'package:flutter/material.dart';

import '../theme/berga_colors.dart';
import '../theme/berga_sizes.dart';
import '../theme/berga_text.dart';
import 'app_text_field.dart';
import 'buttons.dart';

/// Pede um texto (ex.: nome da playlist). Devolve nulo se cancelar.
Future<String?> showTextInputDialog(
  BuildContext context, {
  required String title,
  required String hint,
  String initial = '',
  String confirmLabel = 'Salvar',
}) {
  return showDialog<String>(
    context: context,
    barrierColor: BergaColors.of(context).scrim,
    builder: (_) => _TextInputDialog(
      title: title,
      hint: hint,
      initial: initial,
      confirmLabel: confirmLabel,
    ),
  );
}

class _TextInputDialog extends StatefulWidget {
  const _TextInputDialog({
    required this.title,
    required this.hint,
    required this.initial,
    required this.confirmLabel,
  });

  final String title;
  final String hint;
  final String initial;
  final String confirmLabel;

  @override
  State<_TextInputDialog> createState() => _TextInputDialogState();
}

class _TextInputDialogState extends State<_TextInputDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isNotEmpty) Navigator.of(context).pop(text);
  }

  @override
  Widget build(BuildContext context) {
    final c = BergaColors.of(context);
    return Dialog(
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
              Text(
                widget.title,
                style: BergaText.trackTitle.copyWith(color: c.tx),
              ),
              const SizedBox(height: 12),
              // Borda fina: dentro do diálogo o fundo do campo é igual ao do
              // cartão.
              DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: c.mu.withValues(alpha: 0.4)),
                  borderRadius: BorderRadius.circular(BergaSizes.fieldRadius),
                ),
                child: AppTextField(
                  hint: widget.hint,
                  controller: _controller,
                  autofocus: true,
                  onSubmitted: (_) => _submit(),
                ),
              ),
              const SizedBox(height: 18),
              Align(
                alignment: Alignment.centerRight,
                child: Wrap(
                  spacing: BergaSizes.chipGap,
                  children: [
                    AppChip(
                      label: 'Cancelar',
                      onTap: () => Navigator.of(context).pop(),
                    ),
                    AppChip(
                      label: widget.confirmLabel,
                      active: true,
                      onTap: _submit,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
