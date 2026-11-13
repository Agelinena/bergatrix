import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/theme.dart';
import 'core/widgets.dart';
import 'data/models.dart';
import 'settings/prefs.dart';
import 'settings/settings_screen.dart';
import 'spaces/invite.dart';
import 'spaces/spaces_screen.dart';
import 'sync/sync_badge.dart';
import 'sync/sync_controller.dart';
import 'today/today_screen.dart';

/// Abre o banco local da pessoa e então mostra o app.
class StoreGate extends ConsumerWidget {
  const StoreGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(localStoreProvider);
    return store.when(
      data: (_) => const Shell(),
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(
        body: MessageView(
          icon: Icons.storage,
          title: 'Não deu para abrir os dados do aparelho',
          message: '$e',
        ),
      ),
    );
  }
}

/// Telas de cada aba. Um módulo novo entra aqui e no TabId.
Widget _tabBody(TabId tab) => switch (tab) {
  TabId.today => const TodayScreen(),
  _ => MessageView(icon: Icons.construction, title: '${tab.label} chega numa próxima versão'),
};

IconData _tabIcon(TabId tab, {bool selected = false}) => switch (tab) {
  TabId.today => selected ? Icons.today : Icons.today_outlined,
  TabId.shopping => selected ? Icons.shopping_cart : Icons.shopping_cart_outlined,
  TabId.recurring => selected ? Icons.event_repeat : Icons.event_repeat_outlined,
  TabId.calendar => selected ? Icons.calendar_month : Icons.calendar_month_outlined,
  TabId.notes => selected ? Icons.sticky_note_2 : Icons.sticky_note_2_outlined,
};

/// Barra inferior no celular, trilho lateral no computador e na web larga.
class Shell extends ConsumerStatefulWidget {
  const Shell({super.key});

  @override
  ConsumerState<Shell> createState() => _ShellState();
}

class _ShellState extends ConsumerState<Shell> {
  TabId _tab = TabId.today;

  @override
  void initState() {
    super.initState();
    // Liga o sync e abre um convite que chegou pelo link.
    ref.read(syncProvider);
    Future.microtask(() async {
      final token = await ref.read(pendingInviteProvider).take();
      if (token != null && mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => AcceptInviteScreen(token: token)),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(syncProvider.select((s) => s.phase));
    final prefs = ref.watch(prefsProvider).value ?? Prefs.fallback;
    var tabs = prefs.visibleTabs;
    if (tabs.isEmpty) tabs = const [TabId.today];
    final tab = tabs.contains(_tab) ? _tab : tabs.first;
    final index = tabs.indexOf(tab);
    final wide = MediaQuery.sizeOf(context).width >= wideLayout;

    final body = _tabBody(tab);
    final appBar = AppBar(
      title: Text(tab == TabId.today ? 'Doberga' : tab.label),
      actions: [
        const SyncBadge(),
        IconButton(
          tooltip: 'Ajustes',
          icon: const Icon(Icons.settings_outlined),
          onPressed: () => openSettings(context),
        ),
      ],
    );

    if (wide && tabs.length > 1) {
      return Scaffold(
        appBar: appBar,
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: index,
              labelType: NavigationRailLabelType.all,
              onDestinationSelected: (i) => setState(() => _tab = tabs[i]),
              destinations: [
                for (final t in tabs)
                  NavigationRailDestination(
                    icon: Icon(_tabIcon(t)),
                    selectedIcon: Icon(_tabIcon(t, selected: true)),
                    label: Text(t.label),
                  ),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: body),
          ],
        ),
      );
    }
    return Scaffold(
      appBar: appBar,
      body: body,
      bottomNavigationBar: tabs.length < 2
          ? null
          : NavigationBar(
              selectedIndex: index,
              onDestinationSelected: (i) => setState(() => _tab = tabs[i]),
              destinations: [
                for (final t in tabs)
                  NavigationDestination(
                    icon: Icon(_tabIcon(t)),
                    selectedIcon: Icon(_tabIcon(t, selected: true)),
                    label: t.label,
                  ),
              ],
            ),
    );
  }
}
