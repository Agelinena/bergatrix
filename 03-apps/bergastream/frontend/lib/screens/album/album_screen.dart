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

class AlbumScreen extends ConsumerStatefulWidget {
  final String id;
  const AlbumScreen({super.key, required this.id});

  @override
  ConsumerState<AlbumScreen> createState() => _AlbumScreenState();
}

class _AlbumScreenState extends ConsumerState<AlbumScreen> {
  Map<String, dynamic>? _album;
  List<Track> _tracks = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String get _cacheKey => 'album_${widget.id}';

  Future<void> _load() async {
    // Render cached payload first so the screen works offline.
    final cached = await OfflineCache.getMap(_cacheKey);
    if (cached != null && mounted) {
      try {
        setState(() {
          _album = cached['album'] as Map<String, dynamic>?;
          _tracks = ((cached['tracks'] as List?) ?? const [])
              .map((t) => Track.fromJson(t as Map<String, dynamic>))
              .toList();
          _loading = false;
        });
      } catch (_) {}
    }

    final client = ref.read(apiClientProvider);
    try {
      final data = await client.dio.get('/api/album/${widget.id}');
      final payload = data.data as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _album = payload['album'] as Map<String, dynamic>?;
        _tracks = (payload['tracks'] as List<dynamic>)
            .map((t) => Track.fromJson(t as Map<String, dynamic>))
            .toList();
        _loading = false;
      });
      await OfflineCache.set(_cacheKey, payload);
    } catch (_) {
      if (!mounted) return;
      // Keep cached data if we already have it; otherwise drop loading.
      if (_album == null) setState(() => _loading = false);
    }
  }

  void _playAll() {
    if (_tracks.isNotEmpty) {
      ref.read(playerProvider.notifier).play(_tracks.first, queue: _tracks);
    }
  }

  void _shuffle() {
    if (_tracks.isEmpty) return;
    final shuffled = [..._tracks]..shuffle();
    ref.read(playerProvider.notifier).play(shuffled.first, queue: shuffled);
    ref.read(playerProvider.notifier).toggleShuffle();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator(color: AppColors.primary)));

    final totalMs = _tracks.fold(0, (sum, t) => sum + (t.durationMs ?? 0));
    final totalMin = totalMs ~/ 60000;
    final artistId = _tracks.isNotEmpty ? _tracks.first.artistId : null;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 260,
            pinned: true,
            flexibleSpace: FlexibleSpaceBar(
              background: _album?['cover_url'] != null
                  ? CachedNetworkImage(imageUrl: _album!['cover_url'] as String, fit: BoxFit.cover)
                  : Container(color: AppColors.surfaceVariant),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_album?['title'] ?? '', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  // Artist name — tappable if we have an artist_id
                  GestureDetector(
                    onTap: artistId != null ? () => context.push('/artist/$artistId') : null,
                    child: Text(
                      _album?['artist'] ?? '',
                      style: TextStyle(
                        color: artistId != null ? AppColors.primary : AppColors.textSecondary,
                        fontWeight: artistId != null ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (_album?['year'] != null) '${_album!['year']}',
                      '${_tracks.length} faixas',
                      '$totalMin min',
                    ].join(' · '),
                    style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      ElevatedButton.icon(
                        onPressed: _playAll,
                        icon: const Icon(Icons.play_arrow, size: 18),
                        label: const Text('Tocar'),
                      ),
                      const SizedBox(width: 12),
                      OutlinedButton.icon(
                        onPressed: _shuffle,
                        icon: const Icon(Icons.shuffle, size: 18),
                        label: const Text('Aleatório'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.textPrimary,
                          side: const BorderSide(color: AppColors.textSecondary),
                          shape: const StadiumBorder(),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (_, i) => TrackCard(
                track: _tracks[i],
                queue: _tracks,
                enableSwipeEnqueue: true,
                swipeKeySuffix: 'album',
              ),
              childCount: _tracks.length,
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 80)),
        ],
      ),
    );
  }
}
