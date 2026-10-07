import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/routes.dart';
import '../../core/network/api_error.dart';
import '../../core/platform/app_layout.dart';
import '../../core/theme/berga_colors.dart';
import '../../core/theme/berga_sizes.dart';
import '../../core/theme/berga_text.dart';
import '../../core/widgets/widgets.dart';
import '../../data/local/database.dart';
import '../../data/repositories/local_playlists.dart';
import '../downloads/download_manager.dart';
import '../../data/repositories/playlist_repository.dart';
import '../auth/session.dart';
import 'library_providers.dart';

/// Aba Biblioteca (Seção 6.4): playlists do servidor (suas e compartilhadas)
/// e as locais ("Só neste aparelho").
class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = BergaColors.of(context);
    final mu = BergaText.secondary.copyWith(color: c.mu);
    final server = ref.watch(myPlaylistsProvider);
    final local = ref.watch(localPlaylistsProvider);
    final serverList = server.value ?? const [];
    final downloaded = ref.watch(downloadedPlaylistsProvider).value ?? const [];
    final downloadedIds = {for (final d in downloaded) d.id};
    final downloadedUpdatedAt = {
      for (final d in downloaded) d.id: d.serverUpdatedAt,
    };
    final online = ref.watch(sessionProvider.select((s) => s.canUseServer));
    // Sem servidor: as playlists baixadas (Seção 8.6).
    final offline = online ? const <LocalPlaylistRow>[] : downloaded;

    return RefreshIndicator(
      color: c.gr,
      onRefresh: () => ref.refresh(myPlaylistsProvider.future),
      child: ListView(
        key: const PageStorageKey('library'),
        padding: AppLayout.screenPadding(context),
        children: [
          const ScreenTitle('Biblioteca'),
          if (server.hasError)
            Text(
              server.error is ApiException
                  ? (server.error! as ApiException).message
                  : 'Não foi possível carregar as playlists.',
              style: mu,
            ),
          if (server.isLoading && serverList.isEmpty)
            Text('Carregando…', style: mu),
          if (!server.isLoading &&
              serverList.isEmpty &&
              local.isEmpty &&
              offline.isEmpty)
            Text('Nenhuma playlist neste aparelho.', style: mu),
          for (final p in serverList)
            PlaylistRow(
              title: p.name,
              subtitle: playlistSubtitle(
                tracks: p.trackCount,
                people: p.peopleCount,
              ),
              cover: serverImage(ref, p.coverUrl),
              onTap: () => context.push(AppRoutes.playlist(p.id)),
              trailing: !downloadedIds.contains(p.id)
                  ? null
                  : downloadedUpdatedAt[p.id] != p.updatedAt
                  ? Tooltip(
                      message: 'Atualização disponível',
                      child: Icon(Icons.sync, size: 18, color: c.gr),
                    )
                  : const DownloadStateIcon(state: DownloadState.baixada),
            ),
          for (final p in offline)
            PlaylistRow(
              title: p.name,
              subtitle: 'Baixada',
              onTap: () => context.push(AppRoutes.playlist(p.id)),
              trailing: const DownloadStateIcon(state: DownloadState.baixada),
            ),
          for (final p in local)
            PlaylistRow(
              title: p.name,
              subtitle: 'Só neste aparelho',
              onTap: () => context.push(AppRoutes.localPlaylist(p.id)),
            ),
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerLeft,
            child: PrimaryButton(
              label: 'Nova playlist',
              onPressed: () => createPlaylist(context, ref),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Nova playlist": no servidor quando logado; senão, só no aparelho.
Future<void> createPlaylist(BuildContext context, WidgetRef ref) async {
  final name = await showTextInputDialog(
    context,
    title: 'Nova playlist',
    hint: 'Nome da playlist',
    confirmLabel: 'Criar',
  );
  if (name == null || !context.mounted) return;
  if (!ref.read(sessionProvider).canUseServer) {
    final p = await ref.read(localPlaylistsProvider.notifier).create(name);
    if (context.mounted) context.push(AppRoutes.localPlaylist(p.id));
    return;
  }
  try {
    final p = await ref.read(playlistRepositoryProvider).create(name);
    ref.invalidate(myPlaylistsProvider);
    if (context.mounted) context.push(AppRoutes.playlist(p.id));
  } on ApiException catch (e) {
    if (context.mounted) AppToast.show(context, e.message);
  }
}

/// Linha da lista de playlists: capa 56, nome e legenda.
class PlaylistRow extends StatelessWidget {
  const PlaylistRow({
    super.key,
    required this.title,
    required this.subtitle,
    this.cover,
    this.onTap,
    this.coverSize = 56,
    this.trailing,
  });

  final String title;
  final String subtitle;
  final ImageProvider? cover;
  final VoidCallback? onTap;
  final double coverSize;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final c = BergaColors.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          vertical: BergaSizes.trackPaddingVertical,
        ),
        child: Row(
          spacing: BergaSizes.trackGap,
          children: [
            Cover.playlist(size: coverSize, image: cover),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: BergaText.trackTitle.copyWith(color: c.tx),
                  ),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: BergaText.secondary.copyWith(color: c.mu),
                  ),
                ],
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}
