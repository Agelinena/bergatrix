import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shimmer/shimmer.dart';
import '../../core/theme/app_theme.dart';
import '../../providers/auth_provider.dart';
import '../../providers/library_provider.dart';
import '../../models/playlist.dart';
import '../../widgets/cards/track_card.dart';

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

    final hour = DateTime.now().hour;
    final greeting = hour < 12 ? 'Bom dia' : hour < 18 ? 'Boa tarde' : 'Boa noite';

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () => ref.read(libraryProvider.notifier).load(),
        color: AppColors.primary,
        child: CustomScrollView(
          slivers: [
            SliverAppBar(
              title: Text('$greeting, ${user?.username ?? ''}'),
              floating: true,
              actions: [
                IconButton(
                  icon: const Icon(Icons.notifications_outlined),
                  onPressed: () {},
                ),
                IconButton(
                  icon: const Icon(Icons.settings_outlined),
                  onPressed: () {},
                ),
              ],
            ),
            // Quick access playlists grid
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverToBoxAdapter(
                child: library.when(
                  data: (playlists) => _QuickAccessGrid(playlists: playlists.take(6).toList()),
                  loading: () => _ShimmerGrid(),
                  error: (_, __) => const SizedBox.shrink(),
                ),
              ),
            ),
            // Most played section
            const SliverToBoxAdapter(child: _SectionHeader('Mais tocados')),
            SliverToBoxAdapter(child: _ShimmerHorizontal()),

            // Liked songs quick access
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverToBoxAdapter(
                child: _LikedSongsCard(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickAccessGrid extends StatelessWidget {
  final List<Playlist> playlists;
  const _QuickAccessGrid({required this.playlists});

  @override
  Widget build(BuildContext context) {
    if (playlists.isEmpty) return const SizedBox.shrink();
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
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceVariant,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          Container(
            width: 48, height: 48,
            color: AppColors.primary.withOpacity(0.3),
            child: const Icon(Icons.queue_music, color: AppColors.primary),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(playlist.name, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13))),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
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
        child: Container(decoration: BoxDecoration(color: AppColors.surfaceVariant, borderRadius: BorderRadius.circular(4))),
      ),
    );
  }
}

class _ShimmerHorizontal extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 160,
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
            decoration: BoxDecoration(color: AppColors.surfaceVariant, borderRadius: BorderRadius.circular(8)),
          ),
        ),
      ),
    );
  }
}

class _LikedSongsCard extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [Color(0xFF4B2991), Color(0xFF8B5CF6)]),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(Icons.favorite, color: Colors.white, size: 32),
          const SizedBox(width: 16),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Músicas curtidas', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              Text('Ver todas', style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 13)),
            ],
          ),
          const Spacer(),
          const Icon(Icons.chevron_right, color: Colors.white70),
        ],
      ),
    );
  }
}
