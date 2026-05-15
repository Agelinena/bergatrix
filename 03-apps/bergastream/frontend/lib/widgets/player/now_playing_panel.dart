import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../core/theme/app_theme.dart';
import '../../core/constants.dart';
import '../../providers/player_provider.dart';
import '../../providers/ui_provider.dart';

class NowPlayingPanel extends ConsumerWidget {
  const NowPlayingPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    final track = player.currentTrack;

    return Container(
      width: kNowPlayingWidth,
      color: AppColors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
            child: Row(
              children: [
                Text('Fila', style: Theme.of(context).textTheme.titleSmall),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close, size: 20, color: AppColors.textSecondary),
                  tooltip: 'Fechar',
                  onPressed: () => ref.read(nowPlayingVisibleProvider.notifier).state = false,
                ),
              ],
            ),
          ),
          const Divider(height: 1),

          // Now playing
          if (track != null) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text('Tocando agora',
                  style: Theme.of(context)
                      .textTheme
                      .labelSmall
                      ?.copyWith(color: AppColors.primary, fontWeight: FontWeight.w600)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: AspectRatio(
                  aspectRatio: 1,
                  child: track.coverUrl != null
                      ? Image.network(track.coverUrl!, fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => _CoverPlaceholder())
                      : _CoverPlaceholder(),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(track.title,
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 2),
                  const SizedBox(height: 2),
                  Text(track.artist,
                      style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
                      overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            const SizedBox(height: 12),
            const Divider(height: 1),
          ],

          // Upcoming queue
          if (player.queue.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text('A seguir',
                  style: Theme.of(context)
                      .textTheme
                      .labelSmall
                      ?.copyWith(color: AppColors.textSecondary, fontWeight: FontWeight.w600)),
            ),
            Expanded(
              child: ListView.builder(
                padding: EdgeInsets.zero,
                itemCount: player.queue.length,
                itemBuilder: (context, i) {
                  final t = player.queue[i];
                  final isCurrent = i == player.queueIndex;
                  if (isCurrent) return const SizedBox.shrink(); // já mostrado acima
                  final isNext = i == player.queueIndex + 1;
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: t.coverUrl != null
                          ? Image.network(t.coverUrl!,
                              width: 40, height: 40, fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => _SmallPlaceholder())
                          : _SmallPlaceholder(),
                    ),
                    title: Text(t.title,
                        style: TextStyle(
                          fontSize: 13,
                          color: isNext ? AppColors.textPrimary : AppColors.textSecondary,
                          fontWeight: isNext ? FontWeight.w500 : FontWeight.normal,
                        ),
                        overflow: TextOverflow.ellipsis),
                    subtitle: Text(t.artist,
                        style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                        overflow: TextOverflow.ellipsis),
                    onTap: () => ref.read(playerProvider.notifier).play(t, queue: player.queue),
                  );
                },
              ),
            ),
          ] else
            const Expanded(
              child: Center(
                child: Text('Fila vazia',
                    style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
              ),
            ),
        ],
      ),
    );
  }
}

class _CoverPlaceholder extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
        color: AppColors.surfaceVariant,
        child: const Icon(Icons.music_note, color: AppColors.textSecondary, size: 40),
      );
}

class _SmallPlaceholder extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
        width: 40,
        height: 40,
        color: AppColors.surfaceVariant,
        child: const Icon(Icons.music_note, color: AppColors.textSecondary, size: 20),
      );
}
