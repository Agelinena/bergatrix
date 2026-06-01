import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/theme/app_theme.dart';
import '../providers/offline_download_provider.dart';

/// Slim banner pinned just above the MiniPlayer showing the current
/// offline-download progress.  Non-modal — the user can keep using the
/// app while the batch runs.
class OfflineDownloadBanner extends ConsumerWidget {
  const OfflineDownloadBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dl = ref.watch(offlineDownloadProvider);
    if (!dl.active && dl.total == 0) return const SizedBox.shrink();

    final finished = !dl.active && dl.total > 0;
    final cancelled = dl.cancelled && !dl.active;

    return Material(
      color: AppColors.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  finished
                      ? (cancelled ? Icons.cancel_outlined : Icons.check_circle_outline)
                      : Icons.download,
                  size: 18,
                  color: finished ? AppColors.primary : AppColors.textPrimary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _headline(dl, finished, cancelled),
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (dl.active)
                  TextButton(
                    onPressed: () => ref.read(offlineDownloadProvider.notifier).cancel(),
                    child: const Text('Cancelar', style: TextStyle(fontSize: 12)),
                  )
                else
                  IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: () =>
                        ref.read(offlineDownloadProvider.notifier).dismiss(),
                  ),
              ],
            ),
            if (dl.active) ...[
              const SizedBox(height: 6),
              LinearProgressIndicator(
                value: dl.progress,
                color: AppColors.primary,
                backgroundColor: AppColors.surfaceVariant,
                minHeight: 3,
              ),
              if (dl.current != null) ...[
                const SizedBox(height: 4),
                Text(
                  '${dl.current!.title} — ${dl.current!.artist}',
                  style: const TextStyle(color: AppColors.textSecondary, fontSize: 11),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  String _headline(OfflineDownloadState dl, bool finished, bool cancelled) {
    if (finished) {
      if (cancelled) {
        return 'Download cancelado — ${dl.done}/${dl.total} baixadas';
      }
      return 'Concluído: ${dl.done}/${dl.total} baixadas'
          '${dl.failed > 0 ? " (${dl.failed} falharam)" : ""}';
    }
    if (dl.waitingForNetwork) {
      return 'Aguardando conexão… ${dl.done}/${dl.total}';
    }
    return 'Baixando ${dl.label} — ${dl.done}/${dl.total}'
        '${dl.failed > 0 ? " (${dl.failed} erros)" : ""}';
  }
}
