import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/berga_colors.dart';
import '../../core/utils/format.dart';
import '../../core/widgets/widgets.dart';
import '../../data/local/database.dart';
import '../../data/models/playlist_models.dart';
import 'download_manager.dart';

/// Botão de download na playlist (Seção 8.4). Só no app (Android/Windows/
/// Linux) e logado; na web não existe.
class PlaylistDownloadButton extends ConsumerWidget {
  const PlaylistDownloadButton({super.key, required this.playlist});

  final PlaylistDetail playlist;

  /// 192 kbps ≈ 24 KB por segundo (faixas ainda não prontas no servidor).
  static int estimateBytes(PlaylistDetail p) => p.tracks.fold(
    0,
    (sum, t) => sum + (t.sizeBytes ?? t.durationSeconds * 24000),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manager = ref.read(downloadManagerProvider.notifier);
    if (!manager.available || playlist.tracks.isEmpty) {
      return const SizedBox.shrink();
    }
    final c = BergaColors.of(context);
    final progress =
        ref.watch(playlistDownloadProvider(playlist.id)).value ??
        PlaylistDownloadProgress.none;
    final waitingWifi = ref.watch(
      downloadManagerProvider.select((s) => s.waitingForWifi),
    );

    switch (progress.state) {
      case PlaylistDownloadState.naoBaixada:
        return AppChip(
          label: 'Baixar no aparelho',
          icon: Icons.download,
          onTap: () async {
            final mb = formatBytes(estimateBytes(playlist));
            final choice = await showChoiceDialog(
              context,
              message:
                  'Baixar ${playlist.tracks.length} músicas, cerca de $mb?',
              options: const ['Cancelar', 'Baixar'],
            );
            if (choice == 1) await manager.downloadPlaylist(playlist);
          },
        );
      case PlaylistDownloadState.baixando:
        final count = '${progress.done}/${progress.total}';
        return AppChip(
          label: waitingWifi ? 'Aguardando Wi-Fi $count' : 'Baixando $count',
          leading: SizedBox.square(
            dimension: 14,
            child: CircularProgressIndicator(
              value: progress.total == 0
                  ? null
                  : progress.done / progress.total,
              strokeWidth: 2,
              color: c.gr,
              backgroundColor: c.track,
            ),
          ),
          onTap: () async {
            final choice = await showChoiceDialog(
              context,
              message: 'Download de ${playlist.name}',
              options: const ['Cancelar download', 'Pausar'],
            );
            if (choice == 0) await manager.removeDownload(playlist.id);
            if (choice == 1) await manager.pause(playlist.id);
          },
        );
      case PlaylistDownloadState.parcial:
        return AppChip(
          label: progress.paused
              ? 'Continuar (${progress.remaining})'
              : 'Baixar restantes (${progress.remaining})',
          icon: Icons.download,
          onTap: () => progress.paused
              ? manager.resume(playlist.id)
              : manager.downloadPlaylist(playlist),
        );
      case PlaylistDownloadState.baixada:
        return AppChip(
          label: 'Baixada',
          icon: Icons.download_done,
          iconColor: c.gr,
          onTap: () async {
            final choice = await showChoiceDialog(
              context,
              message:
                  '${playlist.name} está no aparelho '
                  '(${formatBytes(progress.bytes)}).',
              options: const ['Remover download', 'Atualizar download'],
            );
            if (choice == 0) await manager.removeDownload(playlist.id);
            if (choice == 1) await manager.downloadPlaylist(playlist);
          },
        );
    }
  }
}
