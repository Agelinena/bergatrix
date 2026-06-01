import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shimmer/shimmer.dart';
import '../../core/error_messages.dart';
import '../../core/storage.dart';
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
  bool _resolvingUrl = false; // true enquanto resolve uma URL colada

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
    AppStorage.getStringList(_historyKey).then((list) {
      if (list != null && mounted) setState(() => _history = list);
    });
  }

  void _saveHistory(String query) {
    final q = query.trim();
    if (q.isEmpty) return;
    final updated = [q, ..._history.where((h) => h != q)].take(_maxHistory).toList();
    _history = updated;
    AppStorage.setStringList(_historyKey, updated).ignore();
  }

  void _removeHistory(String query) {
    setState(() => _history = _history.where((h) => h != query).toList());
    AppStorage.setStringList(_historyKey, _history).ignore();
  }

  void _clearHistory() {
    setState(() => _history = []);
    AppStorage.remove(_historyKey).ignore();
  }

  // ── Busca ─────────────────────────────────────────────────────────────────

  void _search(String q) {
    if (q.trim().isEmpty) return;
    setState(() => _showHistory = false);
    ref.read(searchProvider.notifier).search(q.trim(), source: _selectedSource);
  }

  /// Chamado pelo Enter/Go — salva no histórico antes de buscar (ou resolve URL).
  void _submitSearch(String q) {
    _debounce?.cancel();
    if (q.trim().isEmpty) return;
    if (_isTrackUrl(q.trim())) {
      _resolveAndPlay(q.trim());
      return;
    }
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
    // If pasting a URL, resolve immediately (no debounce)
    if (_isTrackUrl(q.trim())) {
      _debounce = Timer(const Duration(milliseconds: 300), () => _resolveAndPlay(q.trim()));
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 500), () => _search(q));
  }

  /// Clique em item do histórico: preenche o campo e busca imediatamente.
  void _tapHistory(String q) {
    _debounce?.cancel();
    _queryCtrl.text = q;
    _search(q); // já faz setState(_showHistory = false)
  }

  /// Detects if a string is a Spotify/Deezer/YouTube TRACK URL.
  ///
  /// Mirrors backend/app/services/metadata_service.py:_parse_track_url so
  /// the two stay in sync.  In particular:
  ///   * accepts the locale-prefixed Spotify URL `intl-pt/` (and `pt-BR/`,
  ///     `it/`, etc.)  — without this, pasting a Spotify share link from a
  ///     non-en client fell through to a regular text search.
  ///   * accepts the `spotify:track:<id>` URI from the desktop client.
  ///   * accepts music.youtube.com.
  static final _spotifyTrackRe =
      RegExp(r'open\.spotify\.com/(?:[A-Za-z-]+/)?track/[A-Za-z0-9]+');
  static final _deezerTrackRe =
      RegExp(r'deezer\.com/(?:[A-Za-z-]+/)?track/\d+');

  bool _isTrackUrl(String s) {
    if (_spotifyTrackRe.hasMatch(s)) return true;
    if (s.contains('spotify:track:')) return true;
    if (_deezerTrackRe.hasMatch(s)) return true;
    if (s.contains('youtube.com/watch')) return true;
    if (s.contains('music.youtube.com/watch')) return true;
    if (s.contains('youtu.be/')) return true;
    return false;
  }

  /// Resolves a pasted track URL, plays the result and activates radio.
  Future<void> _resolveAndPlay(String url) async {
    setState(() => _resolvingUrl = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final client = ref.read(apiClientProvider);
      final data = await client.resolveTrackUrl(url);
      final track = Track.fromJson(data['track'] as Map<String, dynamic>);
      _playFromSearch(track, [track]);
    } catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text(friendlyError(e, fallback: 'Não foi possível resolver este link.')),
        backgroundColor: Colors.red,
      ));
    } finally {
      if (mounted) setState(() => _resolvingUrl = false);
    }
  }

  void _playFromSearch(Track track, List<Track> queue) async {
    debugPrint('[Search] _playFromSearch START: ${track.title} by ${track.artist} (id=${track.id})');
    // Desativa o rádio ANTES de play() para garantir que o listener do
    // radioQueueProvider não dispare _refill() entre play() e activate().
    // Se não desativarmos, play() muda currentTrack → listener fires → remaining=0
    // → _refill() começa ANTES de activate() ser chamado → dois seeds simultâneos.
    ref.read(radioQueueProvider.notifier).deactivate();
    try {
      // play() já chama registerTrack internamente — não duplicar aqui.
      await ref.read(playerProvider.notifier).play(track, queue: [track]);
      debugPrint('[Search] play() done for ${track.id}');
    } catch (e) {
      debugPrint('[Search] play error: $e');
    }
    try {
      debugPrint('[Search] calling activate(${track.id})');
      await ref.read(radioQueueProvider.notifier).activate(track);
      debugPrint('[Search] activate() done for ${track.id}');
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
            hintText: 'Buscar ou colar link do Spotify/Deezer/YouTube...',
            prefixIcon: _resolvingUrl
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 20, height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
                    ),
                  )
                : const Icon(Icons.search),
            suffixIcon: _queryCtrl.text.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () {
                      _queryCtrl.clear();
                      setState(() { _showHistory = true; _resolvingUrl = false; });
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
                  // "Tocar agora" do menu de 3-pontos também ativa rádio
                  // quando a faixa vem da busca (mesmo comportamento do
                  // clique direto no card).
                  activateRadioOnPlay: true,
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
