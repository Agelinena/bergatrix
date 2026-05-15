// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shimmer/shimmer.dart';
import '../../core/theme/app_theme.dart';
import '../../core/api_client.dart';
import '../../models/track.dart';
import '../../providers/player_provider.dart';
import '../../providers/radio_queue_provider.dart';
import '../../providers/search_provider.dart';
import '../../widgets/cards/track_card.dart';

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen>
    with SingleTickerProviderStateMixin {
  final _queryCtrl = TextEditingController();
  final _focusNode = FocusNode();
  Timer? _debounce;
  String _selectedSource = 'spotify';
  late TabController _tabController;
  final _sources = ['deezer', 'spotify', 'all'];
  final _sourceLabels = ['Deezer', 'Spotify', 'Todos'];
  List<String> _history = [];
  bool _showHistory = true; // começa mostrando histórico (campo vazio + autofocus)

  static const _historyKey = 'search_history';
  static const _maxHistory = 15;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadHistory();
    // Mostrar histórico quando o campo ganha foco e está vazio
    _focusNode.addListener(() {
      if (!mounted) return;
      if (_focusNode.hasFocus && _queryCtrl.text.isEmpty) {
        setState(() => _showHistory = true);
      }
    });
  }

  @override
  void dispose() {
    _queryCtrl.dispose();
    _focusNode.dispose();
    _debounce?.cancel();
    _tabController.dispose();
    super.dispose();
  }

  // ── Histórico ─────────────────────────────────────────────────────────────

  void _loadHistory() {
    try {
      final raw = html.window.localStorage[_historyKey];
      if (raw != null) {
        final list = List<String>.from(jsonDecode(raw));
        setState(() => _history = list);
      }
    } catch (_) {}
  }

  void _saveHistory(String query) {
    final q = query.trim();
    if (q.isEmpty) return;
    final updated = [q, ..._history.where((h) => h != q)].take(_maxHistory).toList();
    _history = updated;
    try {
      html.window.localStorage[_historyKey] = jsonEncode(updated);
    } catch (_) {}
  }

  void _removeHistory(String query) {
    setState(() => _history = _history.where((h) => h != query).toList());
    try {
      html.window.localStorage[_historyKey] = jsonEncode(_history);
    } catch (_) {}
  }

  void _clearHistory() {
    setState(() => _history = []);
    try {
      html.window.localStorage.remove(_historyKey);
    } catch (_) {}
  }

  // ── Busca ─────────────────────────────────────────────────────────────────

  void _search(String q) {
    if (q.trim().isEmpty) return;
    setState(() => _showHistory = false);
    ref.read(searchProvider.notifier).search(q.trim(), source: _selectedSource);
  }

  /// Chamado pelo Enter/Go — salva no histórico antes de buscar.
  void _submitSearch(String q) {
    _debounce?.cancel();
    if (q.trim().isEmpty) return;
    _saveHistory(q);
    _search(q);
  }

  void _onQueryChanged(String q) {
    if (q.isEmpty) {
      setState(() => _showHistory = true);
      _debounce?.cancel();
      return;
    }
    setState(() => _showHistory = false);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () => _search(q));
  }

  /// Clique em item do histórico: preenche o campo e busca imediatamente.
  void _tapHistory(String q) {
    _debounce?.cancel();
    _queryCtrl.text = q;
    _search(q); // já faz setState(_showHistory = false)
  }

  void _playFromSearch(Track track, List<Track> queue) async {
    final client = ref.read(apiClientProvider);
    try {
      await client.registerTrack(track.toJson());
    } catch (e) {
      debugPrint('[Search] registerTrack error: $e');
    }
    try {
      await ref.read(playerProvider.notifier).play(track, queue: [track]);
    } catch (e) {
      debugPrint('[Search] play error: $e');
    }
    try {
      await ref.read(radioQueueProvider.notifier).activate(track);
    } catch (e) {
      debugPrint('[Search] activate error: $e');
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final search = ref.watch(searchProvider);

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _queryCtrl,
          focusNode: _focusNode,
          onChanged: _onQueryChanged,
          onSubmitted: _submitSearch,
          decoration: InputDecoration(
            hintText: 'Buscar músicas, artistas, álbuns...',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: _queryCtrl.text.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () {
                      _queryCtrl.clear();
                      setState(() => _showHistory = true);
                    },
                  )
                : null,
            contentPadding: EdgeInsets.zero,
          ),
          autofocus: true,
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(80),
          child: Column(
            children: [
              SizedBox(
                height: 36,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  itemCount: _sources.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (_, i) => FilterChip(
                    label: Text(_sourceLabels[i]),
                    selected: _selectedSource == _sources[i],
                    onSelected: (_) {
                      setState(() => _selectedSource = _sources[i]);
                      if (_queryCtrl.text.isNotEmpty) _search(_queryCtrl.text);
                    },
                    selectedColor: AppColors.primary.withOpacity(0.2),
                    checkmarkColor: AppColors.primary,
                    labelStyle: TextStyle(
                      color: _selectedSource == _sources[i]
                          ? AppColors.primary
                          : AppColors.textSecondary,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              TabBar(
                controller: _tabController,
                indicatorColor: AppColors.primary,
                tabs: const [
                  Tab(text: 'Músicas'),
                  Tab(text: 'Álbuns'),
                  Tab(text: 'Artistas'),
                ],
              ),
            ],
          ),
        ),
      ),
      body: _showHistory ? _buildHistory(context) : _buildResults(search),
    );
  }

  // ── Histórico inline ───────────────────────────────────────────────────────

  Widget _buildHistory(BuildContext context) {
    if (_history.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.history, size: 64, color: AppColors.textSecondary),
            SizedBox(height: 16),
            Text('Sem pesquisas recentes',
                style: TextStyle(color: AppColors.textSecondary)),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
          child: Row(
            children: [
              Text('Pesquisas recentes',
                  style: Theme.of(context).textTheme.titleSmall),
              const Spacer(),
              TextButton(
                onPressed: _clearHistory,
                child: const Text('Limpar tudo'),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: _history.length,
            itemBuilder: (_, i) {
              final q = _history[i];
              return ListTile(
                leading: const Icon(Icons.history, color: AppColors.textSecondary),
                title: Text(q),
                trailing: IconButton(
                  icon: const Icon(Icons.close,
                      size: 18, color: AppColors.textSecondary),
                  onPressed: () => _removeHistory(q),
                ),
                onTap: () => _tapHistory(q),
              );
            },
          ),
        ),
      ],
    );
  }

  // ── Resultados ─────────────────────────────────────────────────────────────

  Widget _buildResults(SearchState search) {
    if (search.loading) return _ShimmerList();

    return TabBarView(
      controller: _tabController,
      children: [
        // Músicas
        search.tracks.isEmpty
            ? const _EmptyState()
            : ListView.builder(
                itemCount: search.tracks.length,
                itemBuilder: (_, i) => TrackCard(
                  track: search.tracks[i],
                  queue: search.tracks,
                  onTap: () => _playFromSearch(search.tracks[i], search.tracks),
                  showRadioOption: false,
                ),
              ),

        // Álbuns
        search.albums.isEmpty
            ? const _EmptyState()
            : ListView.builder(
                itemCount: search.albums.length,
                itemBuilder: (_, i) {
                  final album = search.albums[i];
                  return ListTile(
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: Image.network(
                        album['cover_url'] ?? '',
                        width: 48,
                        height: 48,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) =>
                            const Icon(Icons.album),
                      ),
                    ),
                    title: Text(album['title'] ?? ''),
                    subtitle: Text(album['artist'] ?? '',
                        style: const TextStyle(
                            color: AppColors.textSecondary)),
                    onTap: () => context.push('/album/${album['id']}'),
                  );
                },
              ),

        // Artistas
        search.artists.isEmpty
            ? const _EmptyState()
            : ListView.builder(
                itemCount: search.artists.length,
                itemBuilder: (_, i) {
                  final artist = search.artists[i];
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundImage: artist['picture_url'] != null
                          ? NetworkImage(artist['picture_url'] as String)
                          : null,
                      child: artist['picture_url'] == null
                          ? const Icon(Icons.person)
                          : null,
                    ),
                    title: Text(artist['name'] ?? ''),
                    onTap: () => context.push('/artist/${artist['id']}'),
                  );
                },
              ),
      ],
    );
  }
}

// ── Widgets auxiliares ─────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.search, size: 64, color: AppColors.textSecondary),
          SizedBox(height: 16),
          Text('Nenhum resultado',
              style: TextStyle(color: AppColors.textSecondary)),
        ],
      ),
    );
  }
}

class _ShimmerList extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemCount: 8,
      itemBuilder: (_, __) => Shimmer.fromColors(
        baseColor: AppColors.surfaceVariant,
        highlightColor: AppColors.surface,
        child: ListTile(
          leading:
              Container(width: 48, height: 48, color: AppColors.surfaceVariant),
          title: Container(height: 14, color: AppColors.surfaceVariant),
          subtitle: Container(height: 12, color: AppColors.surfaceVariant),
        ),
      ),
    );
  }
}
