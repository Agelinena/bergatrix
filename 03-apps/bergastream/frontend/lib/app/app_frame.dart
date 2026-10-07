import 'package:flutter/material.dart';

import '../core/platform/app_layout.dart';
import '../core/platform/app_platform.dart';
import '../core/theme/berga_colors.dart';
import '../core/theme/berga_sizes.dart';

/// Decide o layout e a moldura do app:
/// - **Web:** layout de navegador a partir de 900 px; abaixo disso, layout
///   de celular ocupando a tela toda.
/// - **App** (e a simulação `?modo=android`): layout de celular; em telas
///   largas, numa coluna de até 430 px com cantos de 28 e borda (Seção 6.1).
/// - **Windows/Linux:** layout de navegador a partir de 900 px (com as regras
///   do app); janela estreita, layout de celular na largura toda.
class AppFrame extends StatelessWidget {
  const AppFrame({super.key, required this.platform, required this.child});

  final AppPlatform platform;
  final Widget child;

  static const contentKey = Key('app-frame-content');

  /// A partir desta largura o app (celular) ganha moldura.
  static const framedFrom = 500.0;

  @override
  Widget build(BuildContext context) {
    final c = BergaColors.of(context);
    return ColoredBox(
      color: c.bg,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final kind = AppLayout.kindFor(platform, constraints.maxWidth);
          if (platform.isWeb || platform.isDesktop) {
            return AppLayout(
              kind: kind,
              child: KeyedSubtree(key: contentKey, child: child),
            );
          }

          final content = AppLayout(
            kind: LayoutKind.mobile,
            child: SizedBox(
              key: contentKey,
              width: constraints.maxWidth.clamp(0, BergaSizes.maxContentWidth),
              child: child,
            ),
          );
          if (constraints.maxWidth < framedFrom) return Center(child: content);

          // Dentro da moldura não há barra de status nem área segura.
          final media = MediaQuery.of(context);
          return Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: DecoratedBox(
                position: DecorationPosition.foreground,
                decoration: BoxDecoration(
                  border: Border.all(color: c.card),
                  borderRadius: BorderRadius.circular(28),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(28),
                  child: MediaQuery(
                    data: media.copyWith(
                      padding: EdgeInsets.zero,
                      viewPadding: EdgeInsets.zero,
                    ),
                    child: content,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
