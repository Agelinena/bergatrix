import 'package:flutter/material.dart';

import '../theme/berga_colors.dart';
import '../theme/berga_sizes.dart';
import '../theme/berga_text.dart';
import 'app_text_field.dart';
import 'buttons.dart';

/// Um campo do [showFormDialog].
class FormFieldSpec {
  const FormFieldSpec(
    this.label, {
    this.initial = '',
    this.hint = '',
    this.obscure = false,
    this.keyboardType,
    this.maxLength,
    this.maxLines = 1,
    this.required = true,
  });

  final String label;
  final String initial;
  final String hint;
  final bool obscure;
  final TextInputType? keyboardType;
  final int? maxLength;
  final int maxLines;

  /// Vazio não deixa salvar.
  final bool required;
}

/// Resultado do [showFormDialog]: os textos na ordem dos campos (sem espaços
/// nas pontas, menos as senhas) e a caixa de marcar.
typedef FormResult = ({List<String> values, bool checked});

/// Formulário curto num diálogo (editar perfil, trocar senha, aviso por
/// e-mail). [note] aparece em destaque acima dos campos (avisos de risco);
/// [checkbox] é uma opção como "Avisar por e-mail". [validate] devolve o erro
/// a mostrar (ou nulo). Devolve nulo se cancelar.
Future<FormResult?> showFormDialog(
  BuildContext context, {
  required String title,
  required List<FormFieldSpec> fields,
  String confirmLabel = 'Salvar',
  String? note,
  String? checkbox,
  bool checkboxInitial = true,
  String? Function(List<String> values)? validate,
}) => showDialog<FormResult>(
  context: context,
  barrierColor: BergaColors.of(context).scrim,
  builder: (_) => _FormDialog(
    title: title,
    fields: fields,
    confirmLabel: confirmLabel,
    note: note,
    checkbox: checkbox,
    checkboxInitial: checkboxInitial,
    validate: validate,
  ),
);

class _FormDialog extends StatefulWidget {
  const _FormDialog({
    required this.title,
    required this.fields,
    required this.confirmLabel,
    required this.note,
    required this.checkbox,
    required this.checkboxInitial,
    required this.validate,
  });

  final String title;
  final List<FormFieldSpec> fields;
  final String confirmLabel;
  final String? note;
  final String? checkbox;
  final bool checkboxInitial;
  final String? Function(List<String> values)? validate;

  @override
  State<_FormDialog> createState() => _FormDialogState();
}

class _FormDialogState extends State<_FormDialog> {
  late final _controllers = [
    for (final f in widget.fields) TextEditingController(text: f.initial),
  ];
  late bool _checked = widget.checkboxInitial;
  String? _error;

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final values = [
      for (final (i, f) in widget.fields.indexed)
        f.obscure ? _controllers[i].text : _controllers[i].text.trim(),
    ];
    for (final (i, f) in widget.fields.indexed) {
      if (f.required && values[i].isEmpty) {
        setState(() => _error = 'Preencha "${f.label}".');
        return;
      }
    }
    final error = widget.validate?.call(values);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.of(context).pop((values: values, checked: _checked));
  }

  @override
  Widget build(BuildContext context) {
    final c = BergaColors.of(context);
    final mu = BergaText.secondary.copyWith(color: c.mu);
    return Dialog(
      backgroundColor: c.card,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(BergaSizes.cardRadius),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.title,
                style: BergaText.trackTitle.copyWith(color: c.tx),
              ),
              if (widget.note case final note?) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: c.ac.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(BergaSizes.fieldRadius),
                  ),
                  child: Text(
                    note,
                    style: BergaText.secondary.copyWith(color: c.tx),
                  ),
                ),
              ],
              for (final (i, f) in widget.fields.indexed) ...[
                const SizedBox(height: 12),
                Text(f.label, style: mu),
                const SizedBox(height: 6),
                DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: c.mu.withValues(alpha: 0.4)),
                    borderRadius: BorderRadius.circular(BergaSizes.fieldRadius),
                  ),
                  child: AppTextField(
                    hint: f.hint,
                    controller: _controllers[i],
                    obscureText: f.obscure,
                    keyboardType: f.keyboardType,
                    maxLength: f.maxLength,
                    maxLines: f.maxLines,
                    autofocus: i == 0,
                    textInputAction: i == widget.fields.length - 1
                        ? TextInputAction.done
                        : TextInputAction.next,
                    onSubmitted:
                        i == widget.fields.length - 1 && f.maxLines == 1
                        ? (_) => _submit()
                        : null,
                  ),
                ),
              ],
              if (widget.checkbox case final label?) ...[
                const SizedBox(height: 8),
                InkWell(
                  onTap: () => setState(() => _checked = !_checked),
                  child: Row(
                    children: [
                      Checkbox(
                        value: _checked,
                        activeColor: c.ac,
                        onChanged: (v) => setState(() => _checked = v ?? false),
                      ),
                      Expanded(
                        child: Text(
                          label,
                          style: BergaText.body.copyWith(color: c.tx),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (_error case final error?) ...[
                const SizedBox(height: 8),
                Text(error, style: BergaText.secondary.copyWith(color: c.ac)),
              ],
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
