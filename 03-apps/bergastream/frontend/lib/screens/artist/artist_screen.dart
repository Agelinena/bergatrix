import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_theme.dart';
import '../../core/api_client.dart';
import '../../core/offline_cache.dart';
import '../../models/track.dart';
import '../../providers/player_provider.dart';
import '../../widgets/cards/track_card.dart';

class ArtistScreen extends ConsumerStatefulWidget {
  final String id;
  const ArtistScreen({super.key, required this.id});

  @override
  ConsumerState<ArtistScreen> createState() => _ArtistScreenState();
}

class _ArtistScreenState extends ConsumerState<ArtistScreen>
    with SingleTickerProviderStateMixin {
  Map<String, dynamic>? _artist;
  List<Map<String, dynamic>> _albums = [];
  List<Track> _topTracks = [];
  bool _loading = true;
  late TabController _tabController;

  List<Track> _allTracks = [];
  bool _loadingAll = false;
  bool _hasMore = true;
  int _nextIndex = 0;
  static const _pageSize = 100;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  String get _cacheKey => 'artist_${widget.id}';

  void _applyPayload(Map<String, dynamic> payload) {
    _artist = payload['artist'] as Map<String, dynamic>?;
    _albums = ((payload['albums'] as List?) ?? const [])
        .map((a) => a as Map<String, dynamic>)
        .toList();
    _topTracks = ((payload['top_tracks'] as List?) ?? const [])
        .map((t) => Track.fromJson(t as Map<String, dynamic>))
        .toList();
  }

  Future<void> _load() async {
    final cached = await OfflineCache.getMap(_cacheKey);
    if (cached != null && mounted) {
      try {
        setState(() {
          _applyPayload(cached);
          _loading = false;
        });
      } catch (_) {}
    }

    final client = ref.read(apiClientProvider);
    try {
      final data = await client.dio.get('/api/artist/${widget.id}');
      final payload = data.data as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _applyPayload(payload);
        _loading = false;
      });
      await OfflineCache.set(_cacheKey, payload);
    } catch (_) {
      if (!mounted) return;
      if (_artist == null) setState(() => _loading = false);
    }
  }

  // Loads ALL pages automatically until has_more = false
  Future<void> _loadAllTracks() async {
    if (_loadingAll) return;
    while (_hasMore && mounted) {
      setState(() => _loadingAll = true);
      try {
        final client = ref.read(apiClientProvider);
        final resolvedId = _artist?['id'] as String? ?? widget.id;
        final data = await client.getArtistTracks(resolvedId, index: _nextIndex, limit: _pageSize);
        final tracks = (data['tracks'] as List<dynamic>)
            .map((t) => Track.fromJson(t as Map<String, dynamic>))
            .toList();
        if (!mounted) break;
        setState(() {
          _allTracks.addAll(tracks);
          _nextIndex = data['next_index'] as int? ?? (_nextIndex + tracks.length);
          _hasMore = data['has_more'] as bool? ?? false;
          _loadingAll = false;
        });
        if (tracks.isEmpty) break; // safety valve
      } catch (_) {
        if (mounted) setState(() => _loadingAll = false);
        break;
      }
    }
  }

  void _playAll(List<Track> tracks) {
    if (tracks.isEmpty) return;
    ref.read(playerProvider.notifier).play(tracks.first, queue: tracks);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator(color: AppColors.primary)));
    }

    final nbFan = _artist?['nb_fan'] as int?;

    return Scaffold(
      body: NestedScrollView(
        headerSliverBuilder: (_, __) => [
          SliverAppBar(
            expandedHeight: 220,
            pinned: true,
            flexibleSpace: FlexibleSpaceBar(
              title: Text(
                _artist?['name'] ?? '',
                style: const TextStyle(shadows: [Shadow(blurRadius: 4, color: Colors.black54)]),
              ),
              background: _artist?['picture_url'] != null
                  ? CachedNetworkImage(
                      imageUrl: _artist!['picture_url'] as String,
                      fit: BoxFit.cover,
                      color: Colors.black26,
                      colorBlendMode: BlendMode.darken,
                    )
                  : Container(
                      color: AppColors.surfaceVariant,
                      child: const Icon(Icons.person, size: 80)),
            ),
          ),
          if (nbFan != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: Text('${_formatFans(nbFan)} ouvintes mensais',
                    style: const TextStyle(color: AppColors.textSecondary, fontSize: 13)),
              ),
            ),
          SliverToBoxAdapter(
            child: TabBar(
              controller: _tabController,
              indicatorColor: AppColors.primary,
              onTap: (i) {
                if (i == 1 && _allTracks.isEmpty && !_loadingAll) _loadAllTracks();
              },
              tabs: const [Tab(text: 'Top & Álbuns'), Tab(text: 'Todas as músicas')],
            ),
          ),
        ],
        body: TabBarView(
          controller: _tabController,
          children: [
            _TopAndAlbumsTab(
              topTracks: _topTracks,
              albums: _albums,
              onAlbumTap: (id) => context.push('/album/$id'),
              onPlayAll: () => _playAll(_topTracks),
            ),
            _AllTracksTab(
              tracks: _allTracks,
              loading: _loadingAll,
              hasMore: _hasMore,
              onPlayAll: () => _playAll(_allTracks),
            ),
          ],
        ),
      ),
    );
  }

  String _formatFans(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(0)}K';
    return n.toString();
  }
}

class _TopAndAlbumsTab extends StatelessWidget {
  final List<Track> topTracks;
  final List<Map<String, dynamic>> albums;
  final void Function(String) onAlbumTap;
  final VoidCallback onPlayAll;

  const _TopAndAlbumsTab({
    required this.topTracks,
    required this.albums,
    required this.onAlbumTap,
    required this.onPlayAll,
  });

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        if (topTracks.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Row(
                children: [
                  Text('Top faixas', style: Theme.of(context).textTheme.titleMedium),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: onPlayAll,
                    icon: const Icon(Icons.play_arrow, size: 16),
                    label: const Text('Tocar tudo'),
                  ),
                ],
              ),
            ),
          ),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (_, i) => TrackCard(
                track: topTracks[i],
                queue: topTracks,
                enableSwipeEnqueue: true,
                swipeKeySuffix: 'artist_top',
              ),
              childCount: topTracks.length,
            ),
          ),
        ],
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
            child: Text('Álbuns', style: Theme.of(context).textTheme.titleMedium),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverGrid(
            delegate: SliverChildBuilderDelegate(
              (_, i) {
                final album = albums[i];
                return GestureDetector(
                  onTap: () => onAlbumTap(album['id'] as String),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: album['cover_url'] != null
                              ? CachedNetworkImage(
                                  imageUrl: album['cover_url'] as String, fit: BoxFit.cover)
                              : Container(
                                  color: AppColors.surfaceVariant,
                                  child: const Icon(Icons.album)),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(album['title'] ?? '',
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                          overflow: TextOverflow.ellipsis),
                      Text(album['year']?.toString() ?? '',
                          style: const TextStyle(color: AppColors.textSecondary, fontSize: 11)),
                    ],
                  ),
                );
              },
              childCount: albums.length,
            ),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
              childAspectRatio: 0.82,
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 80)),
      ],
    );
  }
}

class _AllTracksTab extends StatefulWidget {
  final List<Track> tracks;
  final bool loading;
  final bool hasMore;
  final VoidCallback onPlayAll;

  const _AllTracksTab({
    required this.tracks,
    required this.loading,
    required this.hasMore,
    required this.onPlayAll,
  });

  @override
  State<_AllTracksTab> createState() => _AllTracksTabState();
}

class _AllTracksTabState extends State<_AllTracksTab> {
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.tracks.isEmpty && widget.loading) {
      return const Center(child: CircularProgressIndicator(color: AppColors.primary));
    }
    if (widget.tracks.isEmpty) {
      return const Center(
        child: Text('Nenhuma música encontrada', style: TextStyle(color: AppColors.textSecondary)),
      );
    }

    final filtered = _query.isEmpty
        ? widget.tracks
        : widget.tracks.where((t) =>
            t.title.toLowerCase().contains(_query.toLowerCase()) ||
            t.artist.toLowerCase().contains(_query.toLowerCase())).toList();

    return CustomScrollView(
      slivers: [
        // Search bar
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              controller: _searchCtrl,
              onChanged: (q) => setState(() => _query = q),
              decoration: InputDecoration(
                hintText: 'Filtrar músicas...',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _query.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () { _searchCtrl.clear(); setState(() => _query = ''); },
                      )
                    : null,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                isDense: true,
              ),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Row(
              children: [
                Text(
                  _query.isEmpty
                      ? '${widget.tracks.length} músicas${widget.hasMore || widget.loading ? " (carregando...)" : ""}'
                      : '${filtered.length} de ${widget.tracks.length}',
                  style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
                ),
                const Spacer(),
                if (!widget.loading && !widget.hasMore)
                  TextButton.icon(
                    onPressed: widget.onPlayAll,
                    icon: const Icon(Icons.play_arrow, size: 16),
                    label: const Text('Tocar tudo'),
                  ),
              ],
            ),
          ),
        ),
        if (filtered.isEmpty)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: Text('Sem resultados', style: TextStyle(color: AppColors.textSecondary))),
            ),
          )
        else
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (_, i) => TrackCard(
                track: filtered[i],
                queue: filtered,
                enableSwipeEnqueue: true,
                swipeKeySuffix: 'artist_all',
              ),
              childCount: filtered.length,
            ),
          ),
        if (widget.loading)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator(color: AppColors.primary)),
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 80)),
      ],
    );
  }
}
