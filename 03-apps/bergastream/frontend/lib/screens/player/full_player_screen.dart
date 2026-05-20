import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:palette_generator/palette_generator.dart';
import '../../core/theme/app_theme.dart';
import '../../models/track.dart';
import '../../providers/player_provider.dart';

class FullPlayerScreen extends ConsumerStatefulWidget {
  const FullPlayerScreen({super.key});

  @override
  ConsumerState<FullPlayerScreen> createState() => _FullPlayerScreenState();
}

class _FullPlayerScreenState extends ConsumerState<FullPlayerScreen> {
  Color _dominantColor = AppColors.surfaceVariant;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _extractColor());
  }

  Future<void> _extractColor() async {
    final track = ref.read(playerProvider).currentTrack;
    if (track?.coverUrl == null) return;
    try {
      final generator = await PaletteGenerator.fromImageProvider(
        NetworkImage(track!.coverUrl!),
      );
      if (mounted) {
        setState(() => _dominantColor = generator.dominantColor?.color ?? AppColors.surfaceVariant);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final player = ref.watch(playerProvider);
    final track = player.currentTrack;
    if (track == null) return const SizedBox.shrink();

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_dominantColor, AppColors.background],
        ),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            children: [
              const SizedBox(height: 16),
              Container(
                width: 40, height: 4,
                decoration: BoxDecoration(
                  color: Colors.white38,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              // Top bar: queue button (visible only when there's a queue)
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    icon: const Icon(Icons.keyboard_arrow_down),
                    onPressed: () => Navigator.pop(context),
                    tooltip: 'Recolher',
                  ),
                  IconButton(
                    icon: const Icon(Icons.queue_music),
                    tooltip: 'Fila',
                    onPressed: () => _showQueueSheet(context),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // Cover art
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: CachedNetworkImage(
                  imageUrl: track.coverUrl ?? '',
                  width: 300, height: 300, fit: BoxFit.cover,
                  errorWidget: (_, __, ___) => Container(
                    width: 300, height: 300, color: AppColors.surfaceVariant,
                    child: const Icon(Icons.music_note, size: 80),
                  ),
                ),
              ),
              const SizedBox(height: 32),
              // Title & Artist
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(track.title, style: Theme.of(context).textTheme.titleLarge,
                          overflow: TextOverflow.ellipsis),
                        Text(track.artist, style: const TextStyle(color: AppColors.textSecondary, fontSize: 15)),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.favorite_border),
                    onPressed: () {},
                  ),
                ],
              ),
              const SizedBox(height: 20),
              // Progress
              Column(
                children: [
                  Slider(
                    value: player.progress.clamp(0.0, 1.0),
                    onChanged: (v) {
                      final pos = Duration(milliseconds: (v * player.duration.inMilliseconds).round());
                      ref.read(playerProvider.notifier).seekTo(pos);
                    },
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(_fmt(player.position), style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                        Text(_fmt(player.duration), style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // Controls
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  IconButton(
                    icon: Icon(Icons.shuffle, color: player.shuffle ? AppColors.primary : AppColors.textSecondary),
                    iconSize: 28,
                    onPressed: () => ref.read(playerProvider.notifier).toggleShuffle(),
                  ),
                  IconButton(
                    icon: const Icon(Icons.skip_previous),
                    iconSize: 36,
                    onPressed: () => ref.read(playerProvider.notifier).previous(),
                  ),
                  Container(
                    width: 64, height: 64,
                    decoration: const BoxDecoration(color: AppColors.primary, shape: BoxShape.circle),
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      iconSize: 36,
                      icon: Icon(player.isPlaying ? Icons.pause : Icons.play_arrow, color: Colors.black),
                      onPressed: () => ref.read(playerProvider.notifier).togglePlayPause(),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.skip_next),
                    iconSize: 36,
                    onPressed: () => ref.read(playerProvider.notifier).next(),
                  ),
                  IconButton(
                    icon: Icon(
                      player.repeat == RepeatMode.one ? Icons.repeat_one : Icons.repeat,
                      color: player.repeat != RepeatMode.none ? AppColors.primary : AppColors.textSecondary,
                    ),
                    iconSize: 28,
                    onPressed: () => ref.read(playerProvider.notifier).toggleRepeat(),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              // Volume
              Row(
                children: [
                  const Icon(Icons.volume_down, color: AppColors.textSecondary),
                  Expanded(
                    child: Slider(
                      value: player.volume,
                      onChanged: (v) => ref.read(playerProvider.notifier).setVolume(v),
                    ),
                  ),
                  const Icon(Icons.volume_up, color: AppColors.textSecondary),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  void _showQueueSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        builder: (_, scrollController) => _QueueSheet(scrollController: scrollController),
      ),
    );
  }
}

class _QueueSheet extends ConsumerWidget {
  final ScrollController scrollController;
  const _QueueSheet({required this.scrollController});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    final current = player.currentTrack;
    final upcoming = player.queue.skip(player.queueIndex + 1).toList();

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 12),
        Container(
          width: 40, height: 4,
          decoration: BoxDecoration(
            color: Colors.white24,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              Text('Fila',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              Text('${upcoming.length} próximas',
                style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
              ),
            ],
          ),
        ),
        const Divider(),
        Expanded(
          child: upcoming.isEmpty
              ? _EmptyQueue(currentTrack: current)
              : ReorderableListView.builder(
                  scrollController: scrollController,
                  itemCount: upcoming.length,
                  onReorder: (oldIndex, newIndex) {
                    ref.read(playerProvider.notifier).reorderQueue(oldIndex, newIndex);
                  },
                  itemBuilder: (_, i) {
                    final t = upcoming[i];
                    return _QueueRow(
                      // Key only by track id; appending the index breaks
                      // reorder because the index changes on drag.
                      key: ValueKey('queue-${t.id}-$i'),
                      track: t,
                      onTap: () {
                        // Pula direto para esta faixa.
                        final targetIndex = player.queueIndex + 1 + i;
                        if (targetIndex < player.queue.length) {
                          ref.read(playerProvider.notifier).play(
                                player.queue[targetIndex],
                                queue: player.queue,
                              );
                          Navigator.pop(context);
                        }
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _QueueRow extends StatelessWidget {
  final Track track;
  final VoidCallback onTap;
  const _QueueRow({super.key, required this.track, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: CachedNetworkImage(
          imageUrl: track.coverUrl ?? '',
          width: 44, height: 44, fit: BoxFit.cover,
          errorWidget: (_, __, ___) => Container(
            width: 44, height: 44, color: AppColors.surfaceVariant,
            child: const Icon(Icons.music_note, size: 20),
          ),
        ),
      ),
      title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(track.artist,
        style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
        maxLines: 1, overflow: TextOverflow.ellipsis,
      ),
      trailing: const Icon(Icons.drag_handle, color: AppColors.textSecondary),
      onTap: onTap,
    );
  }
}

class _EmptyQueue extends StatelessWidget {
  final Track? currentTrack;
  const _EmptyQueue({this.currentTrack});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.queue_music_outlined, size: 64, color: AppColors.textSecondary),
            const SizedBox(height: 16),
            Text(
              currentTrack != null
                  ? 'Nenhuma próxima faixa na fila'
                  : 'Toque uma música para começar',
              style: const TextStyle(color: AppColors.textSecondary),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
