import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:marquee/marquee.dart';
import '../../core/theme/app_theme.dart';
import '../../core/constants.dart';
import '../../providers/player_provider.dart';
import '../../screens/player/full_player_screen.dart';

class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    final track = player.currentTrack;
    if (track == null) return const SizedBox.shrink();

    return GestureDetector(
      onTap: () => showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => const FullPlayerScreen(),
      ),
      child: Container(
        height: kMiniPlayerHeight,
        color: AppColors.surfaceVariant,
        child: Column(
          children: [
            LinearProgressIndicator(
              value: player.progress,
              backgroundColor: AppColors.surface,
              valueColor: const AlwaysStoppedAnimation(AppColors.primary),
              minHeight: 2,
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: CachedNetworkImage(
                        imageUrl: track.coverUrl ?? '',
                        width: 40,
                        height: 40,
                        fit: BoxFit.cover,
                        errorWidget: (_, __, ___) => Container(
                          width: 40, height: 40,
                          color: AppColors.surface,
                          child: const Icon(Icons.music_note, size: 20),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _MarqueeText(track.title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                          Text(track.artist, style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
                            overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: Icon(player.isPlaying ? Icons.pause : Icons.play_arrow),
                      onPressed: () => ref.read(playerProvider.notifier).togglePlayPause(),
                    ),
                    IconButton(
                      icon: const Icon(Icons.skip_next),
                      onPressed: () => ref.read(playerProvider.notifier).next(),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MarqueeText extends StatelessWidget {
  final String text;
  final TextStyle? style;
  const _MarqueeText(this.text, {this.style});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 18,
      child: Marquee(
        text: text,
        style: style,
        scrollAxis: Axis.horizontal,
        blankSpace: 48,
        velocity: 30,
        startAfter: const Duration(seconds: 2),
        pauseAfterRound: const Duration(seconds: 2),
      ),
    );
  }
}
