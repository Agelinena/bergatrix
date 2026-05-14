import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../core/theme/app_theme.dart';
import '../../core/constants.dart';
import '../../providers/player_provider.dart';
import '../../screens/player/full_player_screen.dart';
import '../../models/track.dart';
import '../cards/track_card.dart';

class PlayerBar extends ConsumerWidget {
  const PlayerBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    final track = player.currentTrack;
    if (track == null) return const SizedBox.shrink();

    return Container(
      color: AppColors.surface,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Seekable progress slider
          _SeekSlider(player: player, ref: ref),
          // Controls row
          SizedBox(
            height: kPlayerBarHeight - 20,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  // Track info — taps to open full player
                  GestureDetector(
                    onTap: () => showModalBottomSheet(
                      context: context,
                      isScrollControlled: true,
                      backgroundColor: Colors.transparent,
                      builder: (_) => const FullPlayerScreen(),
                    ),
                    child: Row(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: CachedNetworkImage(
                            imageUrl: track.coverUrl ?? '',
                            width: 44, height: 44, fit: BoxFit.cover,
                            errorWidget: (_, __, ___) => Container(
                              width: 44, height: 44, color: AppColors.surfaceVariant,
                              child: const Icon(Icons.music_note),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        SizedBox(
                          width: 140,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(track.title,
                                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                                  overflow: TextOverflow.ellipsis),
                              Text(track.artist,
                                  style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
                                  overflow: TextOverflow.ellipsis),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  // Playback controls
                  IconButton(
                    icon: Icon(Icons.shuffle,
                        color: player.shuffle ? AppColors.primary : AppColors.textSecondary, size: 20),
                    onPressed: () => ref.read(playerProvider.notifier).toggleShuffle(),
                    tooltip: 'Aleatório',
                  ),
                  IconButton(
                    icon: const Icon(Icons.skip_previous, size: 26),
                    onPressed: () => ref.read(playerProvider.notifier).previous(),
                  ),
                  Container(
                    width: 38, height: 38,
                    decoration: const BoxDecoration(color: AppColors.primary, shape: BoxShape.circle),
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      icon: Icon(player.isPlaying ? Icons.pause : Icons.play_arrow,
                          color: Colors.black, size: 22),
                      onPressed: () => ref.read(playerProvider.notifier).togglePlayPause(),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.skip_next, size: 26),
                    onPressed: () => ref.read(playerProvider.notifier).next(),
                  ),
                  IconButton(
                    icon: Icon(
                      player.repeat == RepeatMode.one ? Icons.repeat_one : Icons.repeat,
                      color: player.repeat != RepeatMode.none ? AppColors.primary : AppColors.textSecondary,
                      size: 20,
                    ),
                    onPressed: () => ref.read(playerProvider.notifier).toggleRepeat(),
                    tooltip: 'Repetir',
                  ),
                  const Spacer(),
                  // Right side: Queue + More
                  IconButton(
                    icon: const Icon(Icons.queue_music, color: AppColors.textSecondary, size: 22),
                    tooltip: 'Ver fila',
                    onPressed: () => showModalBottomSheet(
                      context: context,
                      backgroundColor: AppColors.surfaceVariant,
                      isScrollControlled: true,
                      builder: (_) => _QueueSheet(
                        queue: player.queue,
                        currentIndex: player.queueIndex,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.more_vert, color: AppColors.textSecondary, size: 22),
                    tooltip: 'Mais opções',
                    onPressed: () => showModalBottomSheet(
                      context: context,
                      backgroundColor: AppColors.surfaceVariant,
                      builder: (_) => TrackMenuSheet(track: track),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SeekSlider extends StatefulWidget {
  final PlayerState player;
  final WidgetRef ref;
  const _SeekSlider({required this.player, required this.ref});

  @override
  State<_SeekSlider> createState() => _SeekSliderState();
}

class _SeekSliderState extends State<_SeekSlider> {
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final value = (_dragging ?? widget.player.progress).clamp(0.0, 1.0);
    return SizedBox(
      height: 20,
      child: SliderTheme(
        data: SliderTheme.of(context).copyWith(
          trackHeight: 3,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
          activeTrackColor: AppColors.primary,
          inactiveTrackColor: AppColors.surfaceVariant,
          thumbColor: AppColors.primary,
          overlayColor: AppColors.primary.withOpacity(0.2),
        ),
        child: Slider(
          value: value,
          onChangeStart: (v) => setState(() => _dragging = v),
          onChanged: (v) => setState(() => _dragging = v),
          onChangeEnd: (v) {
            setState(() => _dragging = null);
            final ms = (v * widget.player.duration.inMilliseconds).round();
            widget.ref.read(playerProvider.notifier).seekTo(Duration(milliseconds: ms));
          },
        ),
      ),
    );
  }
}

class _QueueSheet extends ConsumerWidget {
  final List<Track> queue;
  final int currentIndex;
  const _QueueSheet({required this.queue, required this.currentIndex});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.95,
      expand: false,
      builder: (_, ctrl) => Column(
        children: [
          const SizedBox(height: 8),
          Container(
            width: 40, height: 4,
            decoration: BoxDecoration(
              color: AppColors.textSecondary.withOpacity(0.4),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                Text('Fila de reprodução', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                Text('${queue.length} músicas',
                    style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              controller: ctrl,
              itemCount: queue.length,
              itemBuilder: (_, i) {
                final t = queue[i];
                final isCurrent = i == currentIndex;
                return ListTile(
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: CachedNetworkImage(
                      imageUrl: t.coverUrl ?? '',
                      width: 44, height: 44, fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => Container(
                        width: 44, height: 44, color: AppColors.surfaceVariant,
                        child: const Icon(Icons.music_note, size: 20),
                      ),
                    ),
                  ),
                  title: Text(t.title,
                      style: TextStyle(
                          color: isCurrent ? AppColors.primary : AppColors.textPrimary,
                          fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal),
                      overflow: TextOverflow.ellipsis),
                  subtitle: Text(t.artist,
                      style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
                      overflow: TextOverflow.ellipsis),
                  trailing: isCurrent
                      ? const Icon(Icons.equalizer, color: AppColors.primary, size: 20)
                      : Text(_fmt(Duration(milliseconds: t.durationMs ?? 0)),
                          style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                  onTap: isCurrent ? null : () {
                    Navigator.pop(context);
                    ref.read(playerProvider.notifier).play(t, queue: queue);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
