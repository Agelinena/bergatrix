import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/theme/berga_colors.dart';
import '../core/theme/berga_text.dart';
import '../core/widgets/widgets.dart';
import '../data/models/search_result.dart';
import '../data/repositories/local_playlists.dart';
import '../features/auth/session_banner.dart';
import '../features/library/library_providers.dart';
import '../features/library/library_screen.dart';
import 'routes.dart';
import '../features/player/player_bar.dart';
import '../features/player/player_controller.dart';
import '../features/player/player_messages.dart';
import '../features/player/lyrics.dart';
import '../features/player/queue_panel.dart';
import 'app_shell.dart';

/// Layout de navegador (Seção 6.8), no estilo do Spotify Web: barra lateral
/// com navegação e biblioteca, conteúdo largo e barra do player embaixo.
class DesktopShell extends ConsumerWidget {
  const DesktopShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  static const sidebarWidth = 280.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queueOpen = ref.watch(desktopQueueOpenProvider);
    final lyricsOpen = ref.watch(desktopLyricsOpenProvider);
    final track = ref.watch(playerProvider.select((s) => s.current?.track));
    final hasTrack = ref.watch(playerProvider.select((s) => s.current != null));
    return PlayerMessages(
      child: Scaffold(
        body: Column(
          children: [
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: sidebarWidth,
                    child: _Sidebar(
                      currentIndex: navigationShell.currentIndex,
                      onTab: (index) =>
                          AppShell.goToTab(navigationShell, index),
                    ),
                  ),
                  Expanded(
                    child: Column(
                      children: [
                        const SessionBanner(),
                        Expanded(child: navigationShell),
                      ],
                    ),
                  ),
                  if (queueOpen && hasTrack) const _QueueSidePanel(),
                  if (lyricsOpen && track != null)
                    _LyricsSidePanel(track: track),
                ],
              ),
            ),
            const PlayerBar(),
          ],
        ),
      ),
    );
  }
}

/// Letra à direita (botão Letra da barra do player), rolando com a música.
class _LyricsSidePanel extends StatelessWidget {
  const _LyricsSidePanel({required this.track});

  final SearchResult track;

  @override
  Widget build(BuildContext context) {
    final c = BergaColors.of(context);
    return Container(
      width: 400,
      margin: const EdgeInsets.fromLTRB(0, 8, 8, 8),
      decoration: BoxDecoration(
        color: c.bg,
        border: Border.all(color: c.card),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
            child: Text(
              LyricsCard.title,
              style: BergaText.h2.copyWith(color: c.tx),
            ),
          ),
          Expanded(
            child: LyricsView(
              track: track,
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
            ),
          ),
        ],
      ),
    );
  }
}

/// Painel da fila à direita (botão Fila da barra do player).
class _QueueSidePanel extends StatelessWidget {
  const _QueueSidePanel();

  @override
  Widget build(BuildContext context) {
    final c = BergaColors.of(context);
    return Container(
      width: 360,
      margin: const EdgeInsets.fromLTRB(0, 8, 8, 8),
      decoration: BoxDecoration(
        color: c.bg,
        border: Border.all(color: c.card),
        borderRadius: BorderRadius.circular(14),
      ),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: const [QueuePanel()],
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.currentIndex, required this.onTab});

  final int currentIndex;
  final ValueChanged<int> onTab;

  @override
  Widget build(BuildContext context) {
    final c = BergaColors.of(context);
    BoxDecoration panel() =>
        BoxDecoration(color: c.card, borderRadius: BorderRadius.circular(14));

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 0, 8),
      child: Column(
        spacing: 8,
        children: [
          Container(
            decoration: panel(),
            padding: const EdgeInsets.fromLTRB(8, 16, 8, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                  child: Text(
                    'Bergastream',
                    style: BergaText.h1.copyWith(fontSize: 22, color: c.tx),
                  ),
                ),
                for (final index in [0, 1])
                  _SidebarItem(
                    icon: AppShell.tabs[index].$1,
                    label: AppShell.tabs[index].$2,
                    active: currentIndex == index,
                    onTap: () => onTab(index),
                  ),
              ],
            ),
          ),
          Expanded(
            child: Container(
              decoration: panel(),
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SidebarItem(
                    icon: Icons.library_music,
                    label: 'Sua biblioteca',
                    active: currentIndex == 2,
                    onTap: () => onTab(2),
                  ),
                  const SizedBox(height: 4),
                  const Expanded(child: _SidebarPlaylists()),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Consumer(
                      builder: (context, ref, _) => PrimaryButton(
                        label: 'Nova playlist',
                        onPressed: () => createPlaylist(context, ref),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Container(
            decoration: panel(),
            padding: const EdgeInsets.all(8),
            child: _SidebarItem(
              icon: AppShell.tabs[3].$1,
              label: AppShell.tabs[3].$2,
              active: currentIndex == 3,
              onTap: () => onTab(3),
            ),
          ),
        ],
      ),
    );
  }
}

/// Playlists na barra lateral (servidor + locais).
class _SidebarPlaylists extends ConsumerWidget {
  const _SidebarPlaylists();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final server = ref.watch(myPlaylistsProvider).value ?? const [];
    final local = ref.watch(localPlaylistsProvider);
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      children: [
        for (final p in server)
          PlaylistRow(
            title: p.name,
            subtitle: playlistSubtitle(
              tracks: p.trackCount,
              people: p.peopleCount,
            ),
            cover: serverImage(ref, p.coverUrl),
            coverSize: 48,
            onTap: () => GoRouter.of(context).go(AppRoutes.playlist(p.id)),
          ),
        for (final p in local)
          PlaylistRow(
            title: p.name,
            subtitle: 'Só neste aparelho',
            coverSize: 48,
            onTap: () => GoRouter.of(context).go(AppRoutes.localPlaylist(p.id)),
          ),
      ],
    );
  }
}

class _SidebarItem extends StatelessWidget {
  const _SidebarItem({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = BergaColors.of(context);
    final color = active ? c.ac : c.mu;
    return Semantics(
      button: true,
      selected: active,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            spacing: 14,
            children: [
              Icon(icon, size: 24, color: color),
              Text(
                label,
                style: BergaText.trackTitle.copyWith(
                  color: active ? c.ac : c.tx,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
