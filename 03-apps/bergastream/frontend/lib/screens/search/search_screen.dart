import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shimmer/shimmer.dart';
import '../../core/theme/app_theme.dart';
import '../../providers/search_provider.dart';
import '../../widgets/cards/track_card.dart';

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> with SingleTickerProviderStateMixin {
  final _queryCtrl = TextEditingController();
  Timer? _debounce;
  String _selectedSource = 'deezer';
  late TabController _tabController;
  final _sources = ['deezer', 'spotify', 'youtube', 'all'];
  final _sourceLabels = ['Deezer', 'Spotify', 'YouTube', 'Todos'];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _queryCtrl.dispose();
    _debounce?.cancel();
    _tabController.dispose();
    super.dispose();
  }

  void _onQueryChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      ref.read(searchProvider.notifier).search(q, source: _selectedSource);
    });
  }

  @override
  Widget build(BuildContext context) {
    final search = ref.watch(searchProvider);

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _queryCtrl,
          onChanged: _onQueryChanged,
          decoration: const InputDecoration(
            hintText: 'Buscar músicas, artistas, álbuns...',
            prefixIcon: Icon(Icons.search),
            contentPadding: EdgeInsets.zero,
          ),
          autofocus: true,
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(80),
          child: Column(
            children: [
              // Source selector
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
                      if (_queryCtrl.text.isNotEmpty) {
                        ref.read(searchProvider.notifier).search(_queryCtrl.text, source: _selectedSource);
                      }
                    },
                    selectedColor: AppColors.primary.withOpacity(0.2),
                    checkmarkColor: AppColors.primary,
                    labelStyle: TextStyle(
                      color: _selectedSource == _sources[i] ? AppColors.primary : AppColors.textSecondary,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              // Tabs
              TabBar(
                controller: _tabController,
                indicatorColor: AppColors.primary,
                tabs: const [Tab(text: 'Músicas'), Tab(text: 'Álbuns'), Tab(text: 'Artistas')],
              ),
            ],
          ),
        ),
      ),
      body: search.loading
          ? _ShimmerList()
          : TabBarView(
              controller: _tabController,
              children: [
                // Tracks tab
                search.tracks.isEmpty
                    ? _EmptyState()
                    : ListView.builder(
                        itemCount: search.tracks.length,
                        itemBuilder: (_, i) => TrackCard(
                          track: search.tracks[i],
                          queue: search.tracks,
                        ),
                      ),
                // Albums tab
                search.albums.isEmpty
                    ? _EmptyState()
                    : ListView.builder(
                        itemCount: search.albums.length,
                        itemBuilder: (_, i) {
                          final album = search.albums[i];
                          return ListTile(
                            leading: ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: Image.network(album['cover_url'] ?? '', width: 48, height: 48, fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => const Icon(Icons.album)),
                            ),
                            title: Text(album['title'] ?? ''),
                            subtitle: Text(album['artist'] ?? '', style: const TextStyle(color: AppColors.textSecondary)),
                            onTap: () => context.push('/album/${album['id']}'),
                          );
                        },
                      ),
                // Artists tab
                search.artists.isEmpty
                    ? _EmptyState()
                    : ListView.builder(
                        itemCount: search.artists.length,
                        itemBuilder: (_, i) {
                          final artist = search.artists[i];
                          return ListTile(
                            leading: CircleAvatar(
                              backgroundImage: artist['picture_url'] != null
                                  ? NetworkImage(artist['picture_url'] as String)
                                  : null,
                              child: artist['picture_url'] == null ? const Icon(Icons.person) : null,
                            ),
                            title: Text(artist['name'] ?? ''),
                            onTap: () => context.push('/artist/${artist['id']}'),
                          );
                        },
                      ),
              ],
            ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.search, size: 64, color: AppColors.textSecondary),
          SizedBox(height: 16),
          Text('Nenhum resultado', style: TextStyle(color: AppColors.textSecondary)),
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
          leading: Container(width: 48, height: 48, color: AppColors.surfaceVariant),
          title: Container(height: 14, color: AppColors.surfaceVariant),
          subtitle: Container(height: 12, color: AppColors.surfaceVariant),
        ),
      ),
    );
  }
}
