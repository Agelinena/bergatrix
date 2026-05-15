import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/app_theme.dart';
import '../../core/constants.dart';
import '../../models/track.dart';
import '../../providers/player_provider.dart';
import '../../providers/ui_provider.dart';

class NowPlayingPanel extends ConsumerWidget {
  const NowPlayingPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    final track = player.currentTrack;

    // Upcoming = tudo após o índice atual
    final upcoming = player.queue.skip(player.queueIndex + 1).toList();

    return Container(
      width: kNowPlayingWidth,
      color: AppColors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
            child: Row(
              children: [
                Text('Fila', style: Theme.of(context).textTheme.titleSmall),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close, size: 20, color: AppColors.textSecondary),
                  tooltip: 'Fechar',
                  onPressed: () =>
                      ref.read(nowPlayingVisibleProvider.notifier).state = false,
                ),
              ],
            ),
          ),
          const Divider(height: 1),

          // ── Tocando agora ──────────────────────────────────────────────
          if (track != null) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
              child: Text(
                'Tocando agora',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: AppColors.primary, fontWeight: FontWeight.w600),
              ),
            ),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: track.coverUrl != null
                    ? Image.network(track.coverUrl!,
                        width: 48, height: 48, fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => _Placeholder(size: 48))
                    : _Placeholder(size: 48),
              ),
              title: Text(
                track.title,
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.primary),
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(track.artist,
                  style:
                      const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                  overflow: TextOverflow.ellipsis),
            ),
            const Divider(height: 1),
          ],

          // ── A seguir ───────────────────────────────────────────────────
          if (upcoming.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
              child: Text(
                'A seguir',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: AppColors.textSecondary, fontWeight: FontWeight.w600),
              ),
            ),
            Expanded(
              child: ReorderableListView.builder(
                padding: EdgeInsets.zero,
                itemCount: upcoming.length,
                onReorder: (old, newIdx) =>
                    ref.read(playerProvider.notifier).reorderQueue(old, newIdx),
                proxyDecorator: (child, index, animation) => Material(
                  elevation: 4,
                  color: AppColors.surfaceVariant,
                  borderRadius: BorderRadius.circular(4),
                  child: child,
                ),
                itemBuilder: (context, i) {
                  final t = upcoming[i];
                  final isNext = i == 0;
                  return ListTile(
                    key: ValueKey('${t.id}_$i'),
                    contentPadding:
                        const EdgeInsets.only(left: 12, right: 4, top: 2, bottom: 2),
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: t.coverUrl != null
                          ? Image.network(t.coverUrl!,
                              width: 40, height: 40, fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => _Placeholder(size: 40))
                          : _Placeholder(size: 40),
                    ),
                    title: Text(
                      t.title,
                      style: TextStyle(
                        fontSize: 13,
                        color: isNext
                            ? AppColors.textPrimary
                            : AppColors.textSecondary,
                        fontWeight:
                            isNext ? FontWeight.w500 : FontWeight.normal,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(t.artist,
                        style: const TextStyle(
                            fontSize: 11, color: AppColors.textSecondary),
                        overflow: TextOverflow.ellipsis),
                    trailing: ReorderableDragStartListener(
                      index: i,
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8),
                        child: Icon(Icons.drag_handle,
                            size: 18, color: AppColors.textSecondary),
                      ),
                    ),
                    onTap: () =>
                        ref.read(playerProvider.notifier).play(t, queue: player.queue),
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

class _Placeholder extends StatelessWidget {
  final double size;
  const _Placeholder({required this.size});

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        color: AppColors.surfaceVariant,
        child: Icon(Icons.music_note, color: AppColors.textSecondary, size: size * 0.5),
      );
}
