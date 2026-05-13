import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../core/theme/app_theme.dart';
import '../../core/constants.dart';
import '../../providers/player_provider.dart';
import '../../screens/player/full_player_screen.dart';

class PlayerBar extends ConsumerWidget {
  const PlayerBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    final track = player.currentTrack;
    if (track == null) return const SizedBox.shrink();

    return Container(
      height: kPlayerBarHeight,
      color: AppColors.surface,
      child: Column(
        children: [
          LinearProgressIndicator(
            value: player.progress,
            backgroundColor: AppColors.surfaceVariant,
            valueColor: const AlwaysStoppedAnimation(AppColors.primary),
            minHeight: 3,
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                children: [
                  // Track info
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
                        const SizedBox(width: 12),
                        SizedBox(
                          width: 160,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(track.title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                                overflow: TextOverflow.ellipsis),
                              Text(track.artist, style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
                                overflow: TextOverflow.ellipsis),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Controls (center)
                  const Spacer(),
                  IconButton(
                    icon: Icon(Icons.shuffle, color: player.shuffle ? AppColors.primary : AppColors.textSecondary),
                    onPressed: () => ref.read(playerProvider.notifier).toggleShuffle(),
                  ),
                  IconButton(
                    icon: const Icon(Icons.skip_previous),
                    onPressed: () => ref.read(playerProvider.notifier).previous(),
                  ),
                  Container(
                    width: 40, height: 40,
                    decoration: const BoxDecoration(color: AppColors.primary, shape: BoxShape.circle),
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      icon: Icon(player.isPlaying ? Icons.pause : Icons.play_arrow, color: Colors.black),
                      onPressed: () => ref.read(playerProvider.notifier).togglePlayPause(),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.skip_next),
                    onPressed: () => ref.read(playerProvider.notifier).next(),
                  ),
                  IconButton(
                    icon: Icon(
                      player.repeat == RepeatMode.one ? Icons.repeat_one : Icons.repeat,
                      color: player.repeat != RepeatMode.none ? AppColors.primary : AppColors.textSecondary,
                    ),
                    onPressed: () => ref.read(playerProvider.notifier).toggleRepeat(),
                  ),
                  const Spacer(),
                  // Volume
                  const Icon(Icons.volume_up, color: AppColors.textSecondary, size: 18),
                  SizedBox(
                    width: 100,
                    child: Slider(
                      value: player.volume,
                      onChanged: (v) => ref.read(playerProvider.notifier).setVolume(v),
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
