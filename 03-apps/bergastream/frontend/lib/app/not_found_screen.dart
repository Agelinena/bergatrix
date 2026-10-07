import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/theme/berga_colors.dart';
import '../core/theme/berga_text.dart';
import '../core/widgets/buttons.dart';
import 'routes.dart';

/// Endereço que não existe (link antigo ou digitado errado).
class NotFoundScreen extends StatelessWidget {
  const NotFoundScreen({super.key});

  static const title = 'Página não encontrada';

  @override
  Widget build(BuildContext context) {
    final c = BergaColors.of(context);
    return Scaffold(
      backgroundColor: c.bg,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 12,
            children: [
              Icon(Icons.explore_off_outlined, size: 48, color: c.mu),
              Text(title, style: BergaText.h2.copyWith(color: c.tx)),
              Text(
                'Esse endereço não existe no Bergastream.',
                textAlign: TextAlign.center,
                style: BergaText.secondary.copyWith(color: c.mu),
              ),
              const SizedBox(height: 4),
              PrimaryButton(
                label: 'Ir para o Início',
                onPressed: () => context.go(AppRoutes.home),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
