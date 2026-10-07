import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/routes.dart';
import '../../core/platform/app_layout.dart';
import '../../core/theme/berga_colors.dart';
import '../../core/theme/berga_text.dart';
import '../../core/utils/format.dart';
import '../../core/widgets/widgets.dart';
import '../../data/local/database.dart';
import '../library/library_screen.dart';
import 'download_manager.dart';

/// Espaço usado e quantidade de músicas baixadas.
final downloadsSummaryProvider = StreamProvider<(int, int)>((ref) {
  final db = ref.watch(localDatabaseProvider);
  if (db == null) return Stream.value((0, 0));
  return db.watchDownloadedCount().asyncMap(
    (n) async => (n, await db.usedBytes()),
  );
});

/// "Gerenciar downloads" (Seção 8.5): playlists baixadas com tamanho,
/// espaço total e remover cada uma.
class ManageDownloadsScreen extends ConsumerWidget {
  const ManageDownloadsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = BergaColors.of(context);
    final mu = BergaText.secondary.copyWith(color: c.mu);
    final playlists = ref.watch(downloadedPlaylistsProvider).value ?? const [];
    final (count, bytes) = ref.watch(downloadsSummaryProvider).value ?? (0, 0);
    final manager = ref.read(downloadManagerProvider.notifier);
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: AppLayout.screenPadding(context),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: GestureDetector(
                onTap: () => context.canPop()
                    ? context.pop()
                    : context.go(AppRoutes.settings),
                child: Text('‹ Ajustes', style: mu),
              ),
            ),
            const SizedBox(height: 10),
            const ScreenTitle('Downloads', bottom: 4),
            Text('$count músicas · ${formatBytes(bytes)} usados', style: mu),
            const SizedBox(height: 10),
            if (playlists.isEmpty) Text('Nenhuma playlist baixada.', style: mu),
            for (final p in playlists)
              _DownloadedRow(
                playlist: p,
                onRemove: () => manager.removeDownload(p.id),
              ),
            if (playlists.isNotEmpty) ...[
              const SizedBox(height: 14),
              Align(
                alignment: Alignment.centerLeft,
                child: AppChip(
                  label: 'Apagar todos os downloads',
                  onTap: () => confirmRemoveAll(context, ref),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DownloadedRow extends ConsumerWidget {
  const _DownloadedRow({required this.playlist, required this.onRemove});

  final LocalPlaylistRow playlist;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress =
        ref.watch(playlistDownloadProvider(playlist.id)).value ??
        PlaylistDownloadProgress.none;
    return PlaylistRow(
      title: playlist.name,
      subtitle:
          '${progress.done} de ${progress.total} músicas · '
          '${formatBytes(progress.bytes)}',
      onTap: () => context.push(AppRoutes.playlist(playlist.id)),
      trailing: AppChip(label: 'Remover', onTap: onRemove),
    );
  }
}

/// "Apagar todos os downloads" com confirmação.
Future<void> confirmRemoveAll(BuildContext context, WidgetRef ref) async {
  final choice = await showChoiceDialog(
    context,
    message: 'Apagar todas as músicas baixadas neste aparelho?',
    options: const ['Cancelar', 'Apagar tudo'],
  );
  if (choice != 1) return;
  await ref.read(downloadManagerProvider.notifier).removeAll();
  if (context.mounted) AppToast.show(context, 'Downloads apagados');
}
