import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../core/theme/app_theme.dart';
import '../../core/api_client.dart';
import '../../models/playlist.dart';
import '../../models/track.dart';
import '../../providers/player_provider.dart';
import '../../widgets/cards/track_card.dart';

class PlaylistScreen extends ConsumerStatefulWidget {
  final String id;
  const PlaylistScreen({super.key, required this.id});

  @override
  ConsumerState<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends ConsumerState<PlaylistScreen> {
  Playlist? _playlist;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final client = ref.read(apiClientProvider);
      final data = await client.getPlaylist(widget.id);
      setState(() { _playlist = Playlist.fromJson(data); _loading = false; });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  void _playAll() {
    if (_playlist == null) return;
    final tracks = _playlist!.tracks.map((pt) => pt.track).toList();
    if (tracks.isNotEmpty) {
      ref.read(playerProvider.notifier).play(tracks.first, queue: tracks);
    }
  }

  void _shuffle() {
    if (_playlist == null) return;
    final tracks = [..._playlist!.tracks.map((pt) => pt.track)]..shuffle();
    if (tracks.isNotEmpty) {
      ref.read(playerProvider.notifier).play(tracks.first, queue: tracks);
      ref.read(playerProvider.notifier).toggleShuffle();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator(color: AppColors.primary)));
    if (_playlist == null) return const Scaffold(body: Center(child: Text('Playlist não encontrada')));

    final pl = _playlist!;
    final tracks = pl.tracks.map((pt) => pt.track).toList();
    final totalDuration = tracks.fold(0, (sum, t) => sum + (t.durationMs ?? 0));
    final totalMin = totalDuration ~/ 60000;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 280,
            pinned: true,
            flexibleSpace: FlexibleSpaceBar(
              background: Stack(
                fit: StackFit.expand,
                children: [
                  pl.coverUrl != null
                      ? CachedNetworkImage(imageUrl: pl.coverUrl!, fit: BoxFit.cover)
                      : Container(color: AppColors.surfaceVariant, child: const Icon(Icons.queue_music, size: 80)),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, AppColors.background],
                      ),
                    ),
                  ),
                  Positioned(
                    bottom: 16, left: 16, right: 16,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(pl.name, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                        Text('${tracks.length} músicas · $totalMin min', style: const TextStyle(color: AppColors.textSecondary)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Action buttons
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  ElevatedButton.icon(
                    onPressed: _shuffle,
                    icon: const Icon(Icons.shuffle, size: 18),
                    label: const Text('Aleatório'),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: _playAll,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Tocar tudo'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.textPrimary,
                      side: const BorderSide(color: AppColors.textSecondary),
                      shape: const StadiumBorder(),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Track list
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (_, i) => TrackCard(track: tracks[i], queue: tracks),
              childCount: tracks.length,
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 80)),
        ],
      ),
    );
  }
}
