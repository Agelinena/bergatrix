import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/platform/app_layout.dart';
import '../core/theme/berga_colors.dart';
import '../core/theme/berga_text.dart';
import '../features/auth/session_banner.dart';
import '../features/player/mini_player.dart';
import '../features/player/player_messages.dart';
import 'desktop_shell.dart';

/// Estrutura geral: escolhe o layout de celular (Seção 6.1) ou de
/// navegador (Seção 6.8).
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  /// As 4 abas, na ordem dos ramos do router.
  static const tabs = [
    (Icons.home, 'Início'),
    (Icons.search, 'Buscar'),
    (Icons.library_music, 'Biblioteca'),
    (Icons.settings, 'Ajustes'),
  ];

  /// Troca de aba; tocar na aba atual volta ao início dela.
  static void goToTab(StatefulNavigationShell shell, int index) {
    shell.goBranch(index, initialLocation: index == shell.currentIndex);
  }

  @override
  Widget build(BuildContext context) {
    return AppLayout.isDesktop(context)
        ? DesktopShell(navigationShell: navigationShell)
        : MobileShell(navigationShell: navigationShell);
  }
}

/// Layout de celular: conteúdo, mini player flutuante e barra inferior.
class MobileShell extends ConsumerWidget {
  const MobileShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  /// Distância do mini player até a base (acima da barra de navegação).
  static const miniPlayerBottom = 68.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return PlayerMessages(
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        body: Stack(
          children: [
            Positioned.fill(
              child: SafeArea(
                bottom: false,
                child: Column(
                  children: [
                    const SessionBanner(),
                    Expanded(child: navigationShell),
                  ],
                ),
              ),
            ),
            // Só aparece com faixa carregada (o MiniPlayer some sozinho).
            Positioned(
              left: 10,
              right: 10,
              bottom: miniPlayerBottom + bottomInset,
              child: const MiniPlayer(),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _NavBar(
                currentIndex: navigationShell.currentIndex,
                onTap: (index) => AppShell.goToTab(navigationShell, index),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavBar extends StatelessWidget {
  const _NavBar({required this.currentIndex, required this.onTap});

  final int currentIndex;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final c = BergaColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: c.bg,
        border: Border(top: BorderSide(color: c.card)),
      ),
      padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
      child: Row(
        children: [
          for (final (index, (icon, label)) in AppShell.tabs.indexed)
            Expanded(
              child: Semantics(
                button: true,
                selected: index == currentIndex,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onTap(index),
                  child: Padding(
                    padding: const EdgeInsets.only(top: 10, bottom: 12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      spacing: 2,
                      children: [
                        Icon(
                          icon,
                          size: 20,
                          color: index == currentIndex ? c.ac : c.mu,
                        ),
                        Text(
                          label,
                          style: BergaText.navLabel.copyWith(
                            color: index == currentIndex ? c.ac : c.mu,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
