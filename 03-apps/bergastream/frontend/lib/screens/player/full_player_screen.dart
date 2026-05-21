import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:go_router/go_router.dart';
import 'package:palette_generator/palette_generator.dart';
import '../../core/theme/app_theme.dart';
import '../../models/track.dart';
import '../../providers/player_provider.dart';
import '../../widgets/cast_button.dart';

/// Full-screen now-playing view modelled after Spotify mobile.
///
///   ▾                                                         ⋮
///         (modal handle)
///                ┌───────────────────┐
///                │                   │
///                │   cover (square)  │
///                │                   │
///                └───────────────────┘
///   Próxima: Faixa X
///
///   Title              ♡
///   Artist (clickable)
///   ─────────────────────────────────
///   0:02                          3:49
///   ⇄    ⏮    ⏵    ⏭    ↻
///
///   📡            👥        🗣        ☰
class FullPlayerScreen extends ConsumerStatefulWidget {
  const FullPlayerScreen({super.key});

  @override
  ConsumerState<FullPlayerScreen> createState() => _FullPlayerScreenState();
}

class _FullPlayerScreenState extends ConsumerState<FullPlayerScreen> {
  Color _dominantColor = AppColors.surfaceVariant;
  String? _lastCoverUrl;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _extractColor());
  }

  Future<void> _extractColor() async {
    final track = ref.read(playerProvider).currentTrack;
    if (track?.coverUrl == null || track!.coverUrl == _lastCoverUrl) return;
    _lastCoverUrl = track.coverUrl;
    try {
      final generator = await PaletteGenerator.fromImageProvider(
        NetworkImage(track.coverUrl!),
      );
      if (!mounted) return;
      setState(() => _dominantColor =
          generator.dominantColor?.color ?? AppColors.surfaceVariant);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final player = ref.watch(playerProvider);
    final track = player.currentTrack;
    if (track == null) return const SizedBox.shrink();

    // Re-extract color when track changes.
    if (track.coverUrl != _lastCoverUrl) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _extractColor());
    }

    final hasNext = player.queueIndex + 1 < player.queue.length;
    final nextTrack = hasNext ? player.queue[player.queueIndex + 1] : null;

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_dominantColor, AppColors.background],
          stops: const [0.0, 0.6],
        ),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Top bar
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.keyboard_arrow_down),
                      onPressed: () => Navigator.pop(context),
                      tooltip: 'Recolher',
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.more_vert),
                      onPressed: () {},
                      tooltip: 'Opções',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              // Cover art with subtle shadow
              LayoutBuilder(
                builder: (_, constraints) {
                  final side = (constraints.maxWidth).clamp(240.0, 360.0);
                  return Container(
                    width: side,
                    height: side,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.5),
                          blurRadius: 32,
                          offset: const Offset(0, 16),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: CachedNetworkImage(
                        imageUrl: track.coverUrl ?? '',
                        fit: BoxFit.cover,
                        errorWidget: (_, __, ___) => Container(
                          color: AppColors.surfaceVariant,
                          child: const Center(child: Icon(Icons.music_note, size: 80)),
                        ),
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 36),
              // "Próxima música" hint
              if (nextTrack != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      'Próxima: ${nextTrack.title}',
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 13,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              // Title + artist + favorite
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          track.title,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        // Clickable artist — opens the artist screen if we
                        // have an artistId in the track payload.
                        InkWell(
                          onTap: track.artistId != null
                              ? () {
                                  Navigator.of(context).pop();  // close the modal first
                                  context.push('/artist/${track.artistId}');
                                }
                              : null,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Text(
                              track.artist,
                              style: TextStyle(
                                color: AppColors.textPrimary.withOpacity(0.85),
                                fontSize: 15,
                                decoration: track.artistId != null
                                    ? TextDecoration.none
                                    : TextDecoration.none,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.favorite_border, size: 28),
                    onPressed: () {},
                  ),
                ],
              ),
              const SizedBox(height: 16),
              // Progress
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                ),
                child: Slider(
                  value: player.progress.clamp(0.0, 1.0),
                  onChanged: (v) {
                    final pos = Duration(
                        milliseconds: (v * player.duration.inMilliseconds).round());
                    ref.read(playerProvider.notifier).seekTo(pos);
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(_fmt(player.position),
                        style: const TextStyle(
                            color: AppColors.textSecondary, fontSize: 11)),
                    Text(_fmt(player.duration),
                        style: const TextStyle(
                            color: AppColors.textSecondary, fontSize: 11)),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              // Main controls
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    icon: Icon(Icons.shuffle,
                        color: player.shuffle ? AppColors.primary : AppColors.textPrimary),
                    iconSize: 26,
                    onPressed: () => ref.read(playerProvider.notifier).toggleShuffle(),
                  ),
                  IconButton(
                    icon: const Icon(Icons.skip_previous),
                    iconSize: 40,
                    onPressed: () => ref.read(playerProvider.notifier).previous(),
                  ),
                  Container(
                    width: 72, height: 72,
                    decoration: const BoxDecoration(
                        color: Colors.white, shape: BoxShape.circle),
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      iconSize: 40,
                      icon: Icon(
                          player.isPlaying ? Icons.pause : Icons.play_arrow,
                          color: Colors.black),
                      onPressed: () =>
                          ref.read(playerProvider.notifier).togglePlayPause(),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.skip_next),
                    iconSize: 40,
                    onPressed: () => ref.read(playerProvider.notifier).next(),
                  ),
                  IconButton(
                    icon: Icon(
                      player.repeat == RepeatMode.one
                          ? Icons.repeat_one
                          : Icons.repeat,
                      color: player.repeat != RepeatMode.none
                          ? AppColors.primary
                          : AppColors.textPrimary,
                    ),
                    iconSize: 26,
                    onPressed: () => ref.read(playerProvider.notifier).toggleRepeat(),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              // Bottom row: cast / share / queue
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    // Real CastButton — opens the discover sheet on native,
                    // a "use Chrome to cast" hint on web.
                    const CastButton(),
                    IconButton(
                      icon: const Icon(Icons.share_outlined),
                      iconSize: 22,
                      color: AppColors.textSecondary,
                      onPressed: () {},
                      tooltip: 'Compartilhar',
                    ),
                    IconButton(
                      icon: const Icon(Icons.queue_music),
                      iconSize: 24,
                      color: AppColors.textSecondary,
                      tooltip: 'Fila',
                      onPressed: () => _showQueueSheet(context),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(1, '0');
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
                      key: ValueKey('queue-${t.id}'),  // do NOT include index — breaks reorder
                      track: t,
                      onTap: () {
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
