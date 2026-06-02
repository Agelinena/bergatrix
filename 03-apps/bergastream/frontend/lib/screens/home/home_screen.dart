import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shimmer/shimmer.dart';
import '../../core/api_client.dart';
import '../../core/offline_cache.dart';
import '../../core/theme/app_theme.dart';
import '../../models/playlist.dart';
import '../../models/track.dart';
import '../../providers/auth_provider.dart';
import '../../providers/library_provider.dart';
import '../../providers/player_provider.dart';
import '../../providers/radio_queue_provider.dart';
import '../../widgets/cards/track_card.dart';

/// Últimas faixas únicas ouvidas (deduplica por id, limite 10).
/// Resilient to offline: cached on every successful fetch and falls
/// back to that cache when the network is down.
final _recentTracksProvider = FutureProvider.autoDispose<List<Track>>((ref) async {
  const cacheKey = 'home_recent_tracks';

  List<Track> _parse(List<dynamic> raw) {
    final seen = <String>{};
    final tracks = <Track>[];
    for (final item in raw) {
      final map = item as Map<String, dynamic>;
      final trackData = map['track'] as Map<String, dynamic>?;
      if (trackData == null) continue;
      final t = Track.fromJson(trackData);
      if (seen.add(t.id)) {
        tracks.add(t);
        if (tracks.length >= 10) break;
      }
    }
    return tracks;
  }

  try {
    final data = await ref.read(apiClientProvider).getHistory();
    await OfflineCache.set(cacheKey, data);
    return _parse(data);
  } catch (_) {
    // Fall back to whatever we have cached, even if empty.
    final cached = await OfflineCache.getList(cacheKey);
    return _parse(cached);
  }
});

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(libraryProvider.notifier).load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authProvider).valueOrNull;
    final library = ref.watch(libraryProvider);
    final recentAsync = ref.watch(_recentTracksProvider);

    final hour = DateTime.now().hour;
    final greeting = hour < 12 ? 'Bom dia' : hour < 18 ? 'Boa tarde' : 'Boa noite';

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(_recentTracksProvider);
          await ref.read(libraryProvider.notifier).load();
        },
        color: AppColors.primary,
        child: CustomScrollView(
          slivers: [
            SliverAppBar(
              title: Text('$greeting, ${user?.username ?? ''}'),
              floating: true,
              actions: [
                IconButton(
                  icon: const Icon(Icons.settings_outlined),
                  onPressed: () => context.go('/settings'),
                ),
              ],
            ),

            // ── Acesso rápido ───────────────────────────────────────────
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              sliver: SliverToBoxAdapter(
                child: library.when(
                  data: (playlists) => playlists.isEmpty
                      ? const SizedBox.shrink()
                      : _QuickAccessGrid(playlists: playlists.take(6).toList()),
                  loading: () => _ShimmerGrid(),
                  error: (_, __) => const SizedBox.shrink(),
                ),
              ),
            ),

            // ── Músicas curtidas ────────────────────────────────────────
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              sliver: SliverToBoxAdapter(child: _LikedSongsCard()),
            ),

            // ── Tocadas recentemente ────────────────────────────────────
            const SliverToBoxAdapter(child: _SectionHeader('Tocadas recentemente')),
            SliverToBoxAdapter(
              child: recentAsync.when(
                data: (tracks) => tracks.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        child: Text(
                          'Nenhuma música ouvida ainda.',
                          style: TextStyle(color: AppColors.textSecondary),
                        ),
                      )
                    : _RecentTracksList(tracks: tracks),
                loading: () => _ShimmerHorizontal(),
                error: (_, __) => const SizedBox.shrink(),
              ),
            ),

            const SliverToBoxAdapter(child: SizedBox(height: 32)),
          ],
        ),
      ),
    );
  }
}

// ── Quick access grid ─────────────────────────────────────────────────────────

class _QuickAccessGrid extends StatelessWidget {
  final List<Playlist> playlists;
  const _QuickAccessGrid({required this.playlists});

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 4,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: playlists.length,
      itemBuilder: (_, i) => _QuickAccessCard(playlists[i]),
    );
  }
}

class _QuickAccessCard extends StatelessWidget {
  final Playlist playlist;
  const _QuickAccessCard(this.playlist);

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => context.push('/playlist/${playlist.id}'),
      borderRadius: BorderRadius.circular(4),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surfaceVariant,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: const BorderRadius.horizontal(left: Radius.circular(4)),
              child: playlist.coverUrl != null
                  ? CachedNetworkImage(
                      imageUrl: playlist.coverUrl!,
                      width: 48, height: 48, fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => _PlaylistIcon(),
                    )
                  : _PlaylistIcon(),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                playlist.name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
              ),
            ),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}

class _PlaylistIcon extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
        width: 48, height: 48,
        color: AppColors.primary.withOpacity(0.3),
        child: const Icon(Icons.queue_music, color: AppColors.primary),
      );
}

// ── Liked songs card ──────────────────────────────────────────────────────────

class _LikedSongsCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => context.push('/library/likes'),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF4B2991), Color(0xFF8B5CF6)],
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            const Icon(Icons.favorite, color: Colors.white, size: 32),
            const SizedBox(width: 16),
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Músicas curtidas',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.white),
                ),
                Text(
                  'Ver todas',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ],
            ),
            const Spacer(),
            const Icon(Icons.chevron_right, color: Colors.white70),
          ],
        ),
      ),
    );
  }
}

// ── Recent tracks horizontal list ─────────────────────────────────────────────

class _RecentTracksList extends ConsumerWidget {
  final List<Track> tracks;
  const _RecentTracksList({required this.tracks});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SizedBox(
      height: 168,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: tracks.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (_, i) {
          final track = tracks[i];
          return _RecentTrackCard(
            track: track,
            onTap: () {
              ref.read(radioQueueProvider.notifier).deactivate();
              ref.read(playerProvider.notifier).play(track, queue: tracks);
            },
          );
        },
      ),
    );
  }
}

class _RecentTrackCard extends StatelessWidget {
  final Track track;
  final VoidCallback onTap;
  const _RecentTrackCard({required this.track, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 120,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: CachedNetworkImage(
                imageUrl: track.coverUrl ?? '',
                width: 120, height: 120, fit: BoxFit.cover,
                errorWidget: (_, __, ___) => Container(
                  width: 120, height: 120,
                  color: AppColors.surfaceVariant,
                  child: const Icon(Icons.music_note, size: 40),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              track.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            Text(
              track.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Shared helpers ─────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(title, style: Theme.of(context).textTheme.titleMedium),
    );
  }
}

class _ShimmerGrid extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2, childAspectRatio: 4, crossAxisSpacing: 8, mainAxisSpacing: 8,
      ),
      itemCount: 6,
      itemBuilder: (_, __) => Shimmer.fromColors(
        baseColor: AppColors.surfaceVariant,
        highlightColor: AppColors.surface,
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.surfaceVariant,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
      ),
    );
  }
}

class _ShimmerHorizontal extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 168,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: 5,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (_, __) => Shimmer.fromColors(
          baseColor: AppColors.surfaceVariant,
          highlightColor: AppColors.surface,
          child: Container(
            width: 120, height: 150,
            decoration: BoxDecoration(
              color: AppColors.surfaceVariant,
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
      ),
    );
  }
}
