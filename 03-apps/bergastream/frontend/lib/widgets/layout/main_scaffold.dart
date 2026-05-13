import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/constants.dart';
import '../../core/theme/app_theme.dart';
import '../../providers/auth_provider.dart';
import '../../providers/player_provider.dart';
import '../player/mini_player.dart';
import '../player/player_bar.dart';

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

class _MobileLayout extends ConsumerStatefulWidget {
  final Widget child;
  const _MobileLayout({required this.child});

  @override
  ConsumerState<_MobileLayout> createState() => _MobileLayoutState();
}

class _MobileLayoutState extends ConsumerState<_MobileLayout> {
  int _currentIndex = 0;

  static const _routes = ['/', '/search', '/library', '/settings'];

  @override
  Widget build(BuildContext context) {
    final hasTrack = ref.watch(playerProvider).hasTrack;
    final location = GoRouterState.of(context).matchedLocation;
    final idx = _routes.indexOf(location).clamp(0, _routes.length - 1);

    return Scaffold(
      body: Column(
        children: [
          Expanded(child: widget.child),
          if (hasTrack) const MiniPlayer(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: idx,
        backgroundColor: AppColors.surface,
        indicatorColor: AppColors.surfaceVariant,
        onDestinationSelected: (i) {
          setState(() => _currentIndex = i);
          context.go(_routes[i]);
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Início'),
          NavigationDestination(icon: Icon(Icons.search), label: 'Busca'),
          NavigationDestination(icon: Icon(Icons.library_music_outlined), selectedIcon: Icon(Icons.library_music), label: 'Biblioteca'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Config.'),
        ],
      ),
    );
  }
}

class _DesktopLayout extends ConsumerWidget {
  final Widget child;
  const _DesktopLayout({required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasTrack = ref.watch(playerProvider).hasTrack;
    final location = GoRouterState.of(context).matchedLocation;
    final user = ref.watch(authProvider).valueOrNull;

    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: Row(
              children: [
                _Sidebar(currentLocation: location, username: user?.username ?? ''),
                const VerticalDivider(width: 1),
                Expanded(child: child),
              ],
            ),
          ),
          if (hasTrack) const PlayerBar(),
        ],
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  final String currentLocation;
  final String username;
  const _Sidebar({required this.currentLocation, required this.username});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 220,
      color: AppColors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                const Icon(Icons.music_note, color: AppColors.primary, size: 28),
                const SizedBox(width: 8),
                Text('BergaStream', style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
          ),
          const SizedBox(height: 32),
          _NavItem(icon: Icons.home, label: 'Início', route: '/', current: currentLocation),
          _NavItem(icon: Icons.search, label: 'Busca', route: '/search', current: currentLocation),
          _NavItem(icon: Icons.library_music, label: 'Biblioteca', route: '/library', current: currentLocation),
          _NavItem(icon: Icons.history, label: 'Histórico', route: '/history', current: currentLocation),
          const Spacer(),
          _NavItem(icon: Icons.settings, label: 'Configurações', route: '/settings', current: currentLocation),
          const Divider(),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 16,
                  backgroundColor: AppColors.primary,
                  child: Text(username.isNotEmpty ? username[0].toUpperCase() : '?',
                    style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(username, overflow: TextOverflow.ellipsis)),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String route;
  final String current;

  const _NavItem({required this.icon, required this.label, required this.route, required this.current});

  @override
  Widget build(BuildContext context) {
    final isActive = current == route || (route != '/' && current.startsWith(route));
    return ListTile(
      leading: Icon(icon, color: isActive ? AppColors.primary : AppColors.textSecondary),
      title: Text(label, style: TextStyle(
        color: isActive ? AppColors.textPrimary : AppColors.textSecondary,
        fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
      )),
      onTap: () => context.go(route),
    );
  }
}
