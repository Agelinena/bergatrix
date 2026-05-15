import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:palette_generator/palette_generator.dart';
import '../../core/theme/app_theme.dart';
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
              const SizedBox(height: 24),
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
}
