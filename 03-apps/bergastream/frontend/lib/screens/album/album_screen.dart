import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../core/theme/app_theme.dart';
import '../../core/api_client.dart';
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

  Future<void> _load() async {
    final client = ref.read(apiClientProvider);
    try {
      final data = await client.dio.get('/api/album/${widget.id}');
      setState(() {
        _album = data.data['album'] as Map<String, dynamic>;
        _tracks = (data.data['tracks'] as List<dynamic>)
            .map((t) => Track.fromJson(t as Map<String, dynamic>))
            .toList();
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator(color: AppColors.primary)));

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 240,
            pinned: true,
            flexibleSpace: FlexibleSpaceBar(
              title: Text(_album?['title'] ?? ''),
              background: _album?['cover_url'] != null
                  ? CachedNetworkImage(imageUrl: _album!['cover_url'] as String, fit: BoxFit.cover)
                  : Container(color: AppColors.surfaceVariant),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_album?['artist'] ?? '', style: const TextStyle(color: AppColors.textSecondary)),
                  if (_album?['year'] != null) Text('${_album!['year']}', style: const TextStyle(color: AppColors.textSecondary)),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    onPressed: () {
                      if (_tracks.isNotEmpty) {
                        ref.read(playerProvider.notifier).play(_tracks.first, queue: _tracks);
                      }
                    },
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Tocar álbum'),
                  ),
                ],
              ),
            ),
          ),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (_, i) => TrackCard(track: _tracks[i], queue: _tracks),
              childCount: _tracks.length,
            ),
          ),
        ],
      ),
    );
  }
}
