import 'package:flutter/material.dart';

import '../theme/berga_colors.dart';
import '../theme/berga_sizes.dart';
import '../theme/berga_text.dart';

/// Campo de texto: fundo `card`, raio 12, padding 12×14, sem borda.
class AppTextField extends StatelessWidget {
  const AppTextField({
    super.key,
    required this.hint,
    this.controller,
    this.onChanged,
    this.onSubmitted,
    this.obscureText = false,
    this.suffix,
    this.keyboardType,
    this.textInputAction,
    this.autofocus = false,
    this.autofillHints,
    this.onClear,
  });

  final String hint;
  final TextEditingController? controller;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool obscureText;

  /// Ex.: botão de mostrar/ocultar senha.
  final Widget? suffix;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final bool autofocus;
  final Iterable<String>? autofillHints;

  /// Com [controller]: mostra um "x" que apaga o texto quando há algo
  /// digitado (e chama esta função depois).
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final controller = this.controller;
    if (onClear == null || controller == null) return _field(context, suffix);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => _field(
        context,
        controller.text.isEmpty
            ? suffix
            : IconButton(
                tooltip: 'Limpar',
                icon: const Icon(Icons.close, size: 20),
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  controller.clear();
                  onClear!();
                },
              ),
      ),
    );
  }

  Widget _field(BuildContext context, Widget? suffix) {
    final c = BergaColors.of(context);
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(BergaSizes.fieldRadius),
      borderSide: BorderSide.none,
    );
    return TextField(
      controller: controller,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      obscureText: obscureText,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      autofocus: autofocus,
      autofillHints: autofillHints,
      style: BergaText.body.copyWith(color: c.tx),
      cursorColor: c.ac,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: BergaText.body.copyWith(color: c.mu),
        filled: true,
        fillColor: c.card,
        isDense: true,
        contentPadding: BergaSizes.fieldPadding,
        border: border,
        enabledBorder: border,
        focusedBorder: border,
        suffixIcon: suffix,
        // Sem isso o ícone força 48 px e o campo fica mais alto que os outros.
        suffixIconConstraints: const BoxConstraints(minWidth: 40, minHeight: 0),
        suffixIconColor: c.mu,
      ),
    );
  }
}
