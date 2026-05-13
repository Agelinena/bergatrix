import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_theme.dart';
import '../../core/api_client.dart';

class ArtistScreen extends ConsumerStatefulWidget {
  final String id;
  const ArtistScreen({super.key, required this.id});

  @override
  ConsumerState<ArtistScreen> createState() => _ArtistScreenState();
}

class _ArtistScreenState extends ConsumerState<ArtistScreen> {
  Map<String, dynamic>? _artist;
  List<Map<String, dynamic>> _albums = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final client = ref.read(apiClientProvider);
    try {
      final data = await client.dio.get('/api/artist/${widget.id}');
      setState(() {
        _artist = data.data['artist'] as Map<String, dynamic>;
        _albums = (data.data['albums'] as List<dynamic>).map((a) => a as Map<String, dynamic>).toList();
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
            expandedHeight: 200,
            pinned: true,
            flexibleSpace: FlexibleSpaceBar(
              title: Text(_artist?['name'] ?? ''),
              background: _artist?['picture_url'] != null
                  ? CachedNetworkImage(imageUrl: _artist!['picture_url'] as String, fit: BoxFit.cover)
                  : Container(color: AppColors.surfaceVariant, child: const Icon(Icons.person, size: 80)),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: SliverToBoxAdapter(
              child: Text('Álbuns', style: Theme.of(context).textTheme.titleMedium),
            ),
          ),
          SliverGrid(
            delegate: SliverChildBuilderDelegate(
              (_, i) {
                final album = _albums[i];
                return GestureDetector(
                  onTap: () => context.go('/album/${album['id']}'),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: album['cover_url'] != null
                              ? CachedNetworkImage(imageUrl: album['cover_url'] as String, fit: BoxFit.cover)
                              : Container(color: AppColors.surfaceVariant, child: const Icon(Icons.album)),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(album['title'] ?? '', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                        overflow: TextOverflow.ellipsis),
                      Text(album['year']?.toString() ?? '', style: const TextStyle(color: AppColors.textSecondary, fontSize: 11)),
                    ],
                  ),
                );
              },
              childCount: _albums.length,
            ),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: 0.8,
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 80)),
        ],
      ),
    );
  }
}
