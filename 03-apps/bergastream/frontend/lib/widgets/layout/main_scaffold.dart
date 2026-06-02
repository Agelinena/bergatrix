import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/constants.dart';
import '../../core/theme/app_theme.dart';
import '../../models/playlist.dart';
import '../../providers/auth_provider.dart';
import '../../providers/library_provider.dart';
import '../../providers/player_provider.dart';
import '../../providers/ui_provider.dart';
import '../offline_banner.dart';
import '../offline_download_banner.dart';
import '../player/mini_player.dart';
import '../player/player_bar.dart';
import '../player/now_playing_panel.dart';

class MainScaffold extends ConsumerWidget {
  final Widget child;
  const MainScaffold({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final width = MediaQuery.of(context).size.width;
    final isDesktop = width >= kDesktopBreakpoint;

    return isDesktop ? _DesktopLayout(child: child) : _MobileLayout(child: child);
  }
}

// ── Mobile ─────────────────────────────────────────────────────────────────

class _MobileLayout extends ConsumerStatefulWidget {
  final Widget child;
  const _MobileLayout({required this.child});

  @override
  ConsumerState<_MobileLayout> createState() => _MobileLayoutState();
}

class _MobileLayoutState extends ConsumerState<_MobileLayout> {
  static const _routes = ['/', '/search', '/library', '/settings'];

  @override
  Widget build(BuildContext context) {
    final hasTrack = ref.watch(playerProvider).hasTrack;
    final location = GoRouterState.of(context).matchedLocation;
    final isHome = location == '/';
    final idx = _routes.indexOf(location).clamp(0, _routes.length - 1);

    // Android back-button behaviour, Spotify-style:
    //   - sub-route pushed on top (e.g. /playlist/abc)  → pop the route
    //   - tab other than "/"                            → go to "/"
    //   - already on "/"                                → let Android
    //                                                     send the app
    //                                                     to background.
    //
    // canPop=true tells the framework "the OS may handle this pop";
    // we only allow that when we're on / with nothing stacked.  In
    // every other case onPopInvokedWithResult intercepts and we
    // navigate ourselves.
    final router = GoRouter.of(context);
    final canRouterPop = router.canPop();
    final canNativePop = Navigator.canPop(context);
    // Allow the OS to handle the pop only when there is truly nothing to
    // pop: no router stack, no native Navigator entry (e.g. an open modal).
    return PopScope(
      canPop: isHome && !canRouterPop && !canNativePop,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (canRouterPop) {
          router.pop();
        } else if (canNativePop) {
          // Closes modals/dialogs opened via Navigator (e.g. the full player).
          Navigator.pop(context);
        } else if (!isHome) {
          context.go('/');
        }
      },
      child: Scaffold(
        body: Column(
          children: [
            const OfflineBanner(),
            Expanded(child: widget.child),
            const OfflineDownloadBanner(),
            if (hasTrack) const MiniPlayer(),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: idx,
          backgroundColor: AppColors.surface,
          indicatorColor: AppColors.surfaceVariant,
          onDestinationSelected: (i) {
            context.go(_routes[i]);
          },
          destinations: const [
            NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Início'),
            NavigationDestination(icon: Icon(Icons.search), label: 'Busca'),
            NavigationDestination(icon: Icon(Icons.library_music_outlined), selectedIcon: Icon(Icons.library_music), label: 'Biblioteca'),
            NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Config.'),
          ],
        ),
      ),
    );
  }
}


// ── Desktop ────────────────────────────────────────────────────────────────

class _DesktopLayout extends ConsumerWidget {
  final Widget child;
  const _DesktopLayout({required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasTrack = ref.watch(playerProvider).hasTrack;
    final nowPlayingVisible = ref.watch(nowPlayingVisibleProvider);
    final location = GoRouterState.of(context).matchedLocation;
    final user = ref.watch(authProvider).valueOrNull;

    return Scaffold(
      body: Column(
        children: [
          const OfflineBanner(),
          Expanded(
            child: Row(
              children: [
                // Sidebar esquerda
                _Sidebar(currentLocation: location, username: user?.username ?? ''),
                const VerticalDivider(width: 1),
                // Conteúdo principal
                Expanded(child: child),
                // Painel "Fila / Tocando agora" (direita)
                if (hasTrack && nowPlayingVisible) ...[
                  const VerticalDivider(width: 1),
                  const NowPlayingPanel(),
                ],
              ],
            ),
          ),
          const OfflineDownloadBanner(),
          if (hasTrack) const PlayerBar(),
        ],
      ),
    );
  }
}

// ── Sidebar ────────────────────────────────────────────────────────────────

class _Sidebar extends ConsumerStatefulWidget {
  final String currentLocation;
  final String username;
  const _Sidebar({required this.currentLocation, required this.username});

  @override
  ConsumerState<_Sidebar> createState() => _SidebarState();
}

class _SidebarState extends ConsumerState<_Sidebar> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(libraryProvider.notifier).load();
    });
  }

  Future<void> _showCreatePlaylist() async {
    final nameCtrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceVariant,
        title: const Text('Nova playlist'),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Nome da playlist'),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, nameCtrl.text.trim()),
            child: const Text('Criar'),
          ),
        ],
      ),
    );
    nameCtrl.dispose();
    if (name == null || name.isEmpty || !mounted) return;
    await ref.read(libraryProvider.notifier).createPlaylist(name);
  }

  @override
  Widget build(BuildContext context) {
    final library = ref.watch(libraryProvider);
    final loc = widget.currentLocation;

    return Container(
      width: kSidebarWidth,
      color: AppColors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Logo
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                const Icon(Icons.music_note, color: AppColors.primary, size: 26),
                const SizedBox(width: 8),
                Text('BergaStream',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // Nav items principais
          _NavItem(icon: Icons.home, label: 'Início', route: '/', current: loc),
          _NavItem(icon: Icons.search, label: 'Buscar', route: '/search', current: loc),
          _NavItem(icon: Icons.history, label: 'Histórico', route: '/history', current: loc),

          const SizedBox(height: 12),
          const Divider(height: 1),
          const SizedBox(height: 4),

          // Cabeçalho "Sua Biblioteca"
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
            child: Row(
              children: [
                // Clique no ícone/label abre a tela de biblioteca
                InkWell(
                  onTap: () => context.go('/library'),
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.library_music, size: 18, color: AppColors.textSecondary),
                        const SizedBox(width: 8),
                        Text('Sua Biblioteca',
                            style: Theme.of(context)
                                .textTheme
                                .labelMedium
                                ?.copyWith(color: AppColors.textSecondary)),
                      ],
                    ),
                  ),
                ),
                const Spacer(),
                // Botão "+" abre dialog de criar playlist diretamente
                IconButton(
                  icon: const Icon(Icons.add, size: 18, color: AppColors.textSecondary),
                  tooltip: 'Nova playlist',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: _showCreatePlaylist,
                ),
              ],
            ),
          ),

          // Lista de playlists
          Expanded(
            child: library.when(
              data: (playlists) => playlists.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.fromLTRB(20, 8, 20, 0),
                      child: Text('Nenhuma playlist',
                          style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 8),
                      itemCount: playlists.length,
                      itemBuilder: (_, i) => _PlaylistTile(
                        playlist: playlists[i],
                        current: loc,
                      ),
                    ),
              loading: () => const Padding(
                padding: EdgeInsets.all(20),
                child: SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
                ),
              ),
              error: (_, __) => const SizedBox.shrink(),
            ),
          ),

          // Rodapé: Configurações + usuário
          const Divider(height: 1),
          _NavItem(icon: Icons.settings, label: 'Configurações', route: '/settings', current: loc),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 14,
                  backgroundColor: AppColors.primary,
                  child: Text(
                    widget.username.isNotEmpty ? widget.username[0].toUpperCase() : '?',
                    style: const TextStyle(
                        color: Colors.black, fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(widget.username,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── _PlaylistTile ──────────────────────────────────────────────────────────

class _PlaylistTile extends StatelessWidget {
  final Playlist playlist;
  final String current;
  const _PlaylistTile({required this.playlist, required this.current});

  @override
  Widget build(BuildContext context) {
    final route = '/playlist/${playlist.id}';
    final isActive = current == route;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: playlist.coverUrl != null
            ? Image.network(playlist.coverUrl!,
                width: 40, height: 40, fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _PlaylistCoverFallback())
            : _PlaylistCoverFallback(),
      ),
      title: Text(
        playlist.name,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 13,
          color: isActive ? AppColors.primary : AppColors.textPrimary,
          fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
      subtitle: Text(
        '${playlist.trackCount} músicas',
        style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
      ),
      onTap: () => context.push(route),
    );
  }
}

class _PlaylistCoverFallback extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
        width: 40,
        height: 40,
        color: AppColors.surfaceVariant,
        child: const Icon(Icons.queue_music, size: 20, color: AppColors.textSecondary),
      );
}

// ── _NavItem ───────────────────────────────────────────────────────────────

class _NavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String route;
  final String current;

  const _NavItem({
    required this.icon,
    required this.label,
    required this.route,
    required this.current,
  });

  @override
  Widget build(BuildContext context) {
    final isActive = current == route || (route != '/' && current.startsWith(route));
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
      leading: Icon(icon,
          color: isActive ? AppColors.primary : AppColors.textSecondary, size: 22),
      title: Text(
        label,
        style: TextStyle(
          fontSize: 14,
          color: isActive ? AppColors.textPrimary : AppColors.textSecondary,
          fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
      onTap: () => context.go(route),
    );
  }
}
