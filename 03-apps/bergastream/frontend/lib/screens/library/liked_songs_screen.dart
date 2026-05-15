import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/app_theme.dart';
import '../../core/api_client.dart';
import '../../models/track.dart';
import '../../providers/library_provider.dart';
import '../../providers/player_provider.dart';
import '../../widgets/cards/track_card.dart';

class LikedSongsScreen extends ConsumerStatefulWidget {
  const LikedSongsScreen({super.key});

  @override
  ConsumerState<LikedSongsScreen> createState() => _LikedSongsScreenState();
}

class _LikedSongsScreenState extends ConsumerState<LikedSongsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(likedSongsProvider.notifier).load();
    });
  }

  void _playAll(List<Track> tracks) {
    if (tracks.isEmpty) return;
    ref.read(playerProvider.notifier).play(tracks.first, queue: tracks);
  }

  void _shuffle(List<Track> tracks) {
    if (tracks.isEmpty) return;
    final shuffled = [...tracks]..shuffle();
    ref.read(playerProvider.notifier).play(shuffled.first, queue: shuffled);
  }

  Future<void> _unlike(Track track) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(apiClientProvider).unlikeTrack(track.id);
      await ref.read(likedSongsProvider.notifier).load();
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Erro ao remover curtida'), duration: Duration(seconds: 2)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final likedSongs = ref.watch(likedSongsProvider);

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 200,
            pinned: true,
            flexibleSpace: FlexibleSpaceBar(
              background: Stack(
                fit: StackFit.expand,
                children: [
                  Container(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFF4B2991), Color(0xFF8B5CF6), Color(0xFF3B82F6)],
                      ),
                    ),
                  ),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, AppColors.background],
                      ),
                    ),
                  ),
                  const Positioned(
                    bottom: 16, left: 16,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.favorite, color: Colors.white, size: 48),
                        SizedBox(height: 8),
                        Text('Músicas curtidas',
                            style: TextStyle(
                                fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Botões de ação
          likedSongs.maybeWhen(
            data: (tracks) => SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Row(
                  children: [
                    ElevatedButton.icon(
                      onPressed: tracks.isEmpty ? null : () => _shuffle(tracks),
                      icon: const Icon(Icons.shuffle, size: 18),
                      label: const Text('Aleatório'),
                    ),
                    const SizedBox(width: 12),
                    if (tracks.isNotEmpty)
                      OutlinedButton.icon(
                        onPressed: () => _playAll(tracks),
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('Tocar tudo'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.textPrimary,
                          side: const BorderSide(color: AppColors.textSecondary),
                          shape: const StadiumBorder(),
                        ),
                      ),
                    const Spacer(),
                    Text('${tracks.length} músicas',
                        style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                  ],
                ),
              ),
            ),
            orElse: () => const SliverToBoxAdapter(child: SizedBox.shrink()),
          ),

          // Lista
          likedSongs.when(
            data: (tracks) => tracks.isEmpty
                ? const SliverFillRemaining(
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.favorite_border, size: 64, color: AppColors.textSecondary),
                          SizedBox(height: 16),
                          Text('Nenhuma música curtida ainda',
                              style: TextStyle(color: AppColors.textSecondary)),
                          SizedBox(height: 8),
                          Text('Toque o ❤ em qualquer música para salvar aqui.',
                              style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                        ],
                      ),
                    ),
                  )
                : SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (_, i) => _LikedTrackTile(
                        track: tracks[i],
                        queue: tracks,
                        onUnlike: () => _unlike(tracks[i]),
                      ),
                      childCount: tracks.length,
                    ),
                  ),
            loading: () => const SliverFillRemaining(
              child: Center(child: CircularProgressIndicator(color: AppColors.primary)),
            ),
            error: (e, _) => SliverFillRemaining(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.error_outline, size: 48, color: AppColors.textSecondary),
                    const SizedBox(height: 12),
                    Text('Erro ao carregar: $e',
                        style: const TextStyle(color: AppColors.textSecondary),
                        textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: () => ref.read(likedSongsProvider.notifier).load(),
                      child: const Text('Tentar novamente'),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 80)),
        ],
      ),
    );
  }
}

/// TrackCard com ação de descurtir no menu contextual.
class _LikedTrackTile extends ConsumerWidget {
  final Track track;
  final List<Track> queue;
  final VoidCallback onUnlike;

  const _LikedTrackTile({
    required this.track,
    required this.queue,
    required this.onUnlike,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return TrackCard(
      track: track,
      queue: queue,
      onTap: () => ref.read(playerProvider.notifier).play(track, queue: queue),
      // Não mostra opção de rádio para simplificar
      showRadioOption: true,
    );
  }
}
