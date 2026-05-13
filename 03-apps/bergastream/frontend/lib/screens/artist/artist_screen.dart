import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_theme.dart';
import '../../core/api_client.dart';
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

  // All tracks state
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

  Future<void> _load() async {
    final client = ref.read(apiClientProvider);
    try {
      final data = await client.dio.get('/api/artist/${widget.id}');
      setState(() {
        _artist = data.data['artist'] as Map<String, dynamic>;
        _albums = (data.data['albums'] as List<dynamic>)
            .map((a) => a as Map<String, dynamic>)
            .toList();
        _topTracks = ((data.data['top_tracks'] as List<dynamic>?) ?? [])
            .map((t) => Track.fromJson(t as Map<String, dynamic>))
            .toList();
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  Future<void> _loadAllTracks() async {
    if (_loadingAll || !_hasMore) return;
    setState(() => _loadingAll = true);
    try {
      final client = ref.read(apiClientProvider);
      final data = await client.getArtistTracks(widget.id, index: _nextIndex, limit: _pageSize);
      final tracks = (data['tracks'] as List<dynamic>)
          .map((t) => Track.fromJson(t as Map<String, dynamic>))
          .toList();
      setState(() {
        _allTracks.addAll(tracks);
        _nextIndex = data['next_index'] as int? ?? (_nextIndex + tracks.length);
        _hasMore = data['has_more'] as bool? ?? false;
        _loadingAll = false;
      });
    } catch (_) {
      setState(() => _loadingAll = false);
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
                if (i == 1 && _allTracks.isEmpty) _loadAllTracks();
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
              onLoadMore: _loadAllTracks,
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
              (_, i) => TrackCard(track: topTracks[i], queue: topTracks),
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
  final VoidCallback onLoadMore;
  final VoidCallback onPlayAll;

  const _AllTracksTab({
    required this.tracks,
    required this.loading,
    required this.hasMore,
    required this.onLoadMore,
    required this.onPlayAll,
  });

  @override
  State<_AllTracksTab> createState() => _AllTracksTabState();
}

class _AllTracksTabState extends State<_AllTracksTab> {
  final _scrollCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollCtrl.position.pixels >= _scrollCtrl.position.maxScrollExtent - 300) {
      widget.onLoadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.tracks.isEmpty && widget.loading) {
      return const Center(child: CircularProgressIndicator(color: AppColors.primary));
    }
    if (widget.tracks.isEmpty) {
      return const Center(
        child: Text('Nenhuma música encontrada',
            style: TextStyle(color: AppColors.textSecondary)),
      );
    }

    return CustomScrollView(
      controller: _scrollCtrl,
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Text('${widget.tracks.length} músicas carregadas',
                    style: const TextStyle(color: AppColors.textSecondary, fontSize: 13)),
                const Spacer(),
                TextButton.icon(
                  onPressed: widget.onPlayAll,
                  icon: const Icon(Icons.play_arrow, size: 16),
                  label: const Text('Tocar tudo'),
                ),
              ],
            ),
          ),
        ),
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (_, i) => TrackCard(track: widget.tracks[i], queue: widget.tracks),
            childCount: widget.tracks.length,
          ),
        ),
        if (widget.loading)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator(color: AppColors.primary)),
            ),
          ),
        if (!widget.hasMore && widget.tracks.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: Text('Total: ${widget.tracks.length} músicas',
                    style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
              ),
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 80)),
      ],
    );
  }
}
