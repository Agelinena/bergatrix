import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../articles/article_list.dart';
import '../core/http.dart';
import '../core/prefs.dart';
import '../core/theme.dart';
import '../core/widgets.dart';
import '../data/api.dart';
import '../data/models.dart';
import '../feeds/add_feed.dart';
import '../feeds/feeds_tabs.dart';
import '../search/search_screen.dart';
import '../settings/settings_screen.dart';
import '../stories/story_screen.dart';

const _icons = {
  TabId.all: (Icons.article_outlined, Icons.article),
  TabId.sources: (Icons.rss_feed_outlined, Icons.rss_feed),
  TabId.folders: (Icons.folder_outlined, Icons.folder),
  TabId.stories: (Icons.layers_outlined, Icons.layers),
  TabId.saved: (Icons.bookmark_border, Icons.bookmark),
};

/// Tela inicial: as abas ligadas no painel Aparência, na ordem escolhida.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  TabId _current = TabId.all;
  bool _unreadOnly = false;
  final _allKey = GlobalKey<ArticleListState>();
  final _savedKey = GlobalKey<ArticleListState>();
  final _storiesKey = GlobalKey<StoriesTabState>();

  Future<void> _markAllRead() async {
    final ok = await confirm(
      context,
      title: 'Marcar tudo como lido?',
      message: 'Todas as matérias dos seus veículos até agora.',
      ok: 'Marcar',
    );
    if (!ok || !mounted) return;
    try {
      await ref.read(apiProvider).markRead(before: DateTime.now());
      ref.invalidate(subscriptionsProvider);
      ref.invalidate(foldersProvider);
      await _allKey.currentState?.reload();
    } on Object catch (e) {
      if (mounted) toast(context, describeError(e));
    }
  }

  Widget _tab(TabId id) => switch (id) {
    TabId.all => ArticleList(
      key: _allKey,
      query: ArticleQuery(view: _unreadOnly ? 'unread' : 'all'),
      emptyTitle: _unreadOnly ? 'Tudo lido' : 'Nenhuma matéria ainda',
      emptyMessage: _unreadOnly
          ? null
          : 'Adicione veículos na aba Veículos ou em Ajustes.',
    ),
    TabId.sources => const SourcesTab(),
    TabId.folders => const FoldersTab(),
    TabId.stories => StoriesTab(key: _storiesKey),
    TabId.saved => ArticleList(
      key: _savedKey,
      query: const ArticleQuery(view: 'saved'),
      emptyTitle: 'Nada salvo',
      emptyMessage: 'Toque no marcador no leitor para guardar uma matéria.',
    ),
  };

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(prefsProvider).value ?? Prefs.defaults;
    var tabs = prefs.enabledTabs;
    if (tabs.isEmpty) tabs = const [TabId.all];
    final current = tabs.contains(_current) ? _current : tabs.first;
    final index = tabs.indexOf(current);
    final wide = MediaQuery.sizeOf(context).width >= wideLayout;

    final body = IndexedStack(
      index: index,
      children: [for (final t in tabs) _tab(t)],
    );

    void select(int i) {
      if (tabs[i] == current) {
        // Tocar de novo na aba atual: recarrega.
        switch (current) {
          case TabId.all:
            _allKey.currentState?.reload();
          case TabId.saved:
            _savedKey.currentState?.reload();
          case TabId.stories:
            _storiesKey.currentState?.reload();
          case TabId.sources:
            ref.invalidate(subscriptionsProvider);
          case TabId.folders:
            ref.invalidate(foldersProvider);
        }
      }
      setState(() => _current = tabs[i]);
    }

    final appBar = AppBar(
      title: Text(current == TabId.all ? 'Berganews' : current.label),
      actions: [
        IconButton(
          tooltip: 'Buscar',
          onPressed: () => openSearch(context),
          icon: const Icon(Icons.search),
        ),
        if (current == TabId.all) ...[
          IconButton(
            tooltip: _unreadOnly ? 'Mostrar todas' : 'Só não lidas',
            isSelected: _unreadOnly,
            onPressed: () => setState(() => _unreadOnly = !_unreadOnly),
            icon: const Icon(Icons.filter_list),
          ),
          IconButton(
            tooltip: 'Marcar tudo como lido',
            onPressed: _markAllRead,
            icon: const Icon(Icons.done_all),
          ),
        ],
        IconButton(
          tooltip: 'Ajustes',
          onPressed: () => openSettings(context),
          icon: const Icon(Icons.settings_outlined),
        ),
      ],
    );

    final fab = current == TabId.sources
        ? FloatingActionButton(
            tooltip: 'Adicionar veículo',
            onPressed: () => showAddFeed(context),
            child: const Icon(Icons.add),
          )
        : null;

    if (wide && tabs.length >= 2) {
      return Scaffold(
        appBar: appBar,
        floatingActionButton: fab,
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: index,
              onDestinationSelected: select,
              labelType: NavigationRailLabelType.all,
              destinations: [
                for (final t in tabs)
                  NavigationRailDestination(
                    icon: Icon(_icons[t]!.$1),
                    selectedIcon: Icon(_icons[t]!.$2),
                    label: Text(t.label),
                  ),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: readerWidth + 160),
                  child: body,
                ),
              ),
            ),
          ],
        ),
      );
    }
    return Scaffold(
      appBar: appBar,
      floatingActionButton: fab,
      body: body,
      bottomNavigationBar: tabs.length < 2
          ? null
          : NavigationBar(
              selectedIndex: index,
              onDestinationSelected: select,
              destinations: [
                for (final t in tabs)
                  NavigationDestination(
                    icon: Icon(_icons[t]!.$1),
                    selectedIcon: Icon(_icons[t]!.$2),
                    label: t.label,
                  ),
              ],
            ),
    );
  }
}
