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
import '../../data/models/playlist_models.dart';
import '../auth/session.dart';
import '../playlists/playlist_store.dart';
import '../playlists/sync_notices.dart';
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
    final serverIds = {for (final p in serverList) p.id};
    final downloaded = ref.watch(downloadedPlaylistsProvider).value ?? const [];
    final downloadedIds = {for (final d in downloaded) d.id};
    final downloadedUpdatedAt = {
      for (final d in downloaded) d.id: d.serverUpdatedAt,
    };
    final online = ref.watch(sessionProvider.select((s) => s.canUseServer));
    final pending = ref.watch(pendingPlaylistIdsProvider);
    // Sem servidor: as baixadas que não estão na cópia da lista (Seção 8.6).
    final offline = online
        ? const <LocalPlaylistRow>[]
        : [
            for (final d in downloaded)
              if (!serverIds.contains(d.id)) d,
          ];

    Widget? trailing(ServerPlaylist p) {
      if (pending.contains(p.id)) {
        return Tooltip(
          message: 'Alterações aguardando envio',
          child: Icon(Icons.cloud_upload_outlined, size: 18, color: c.mu),
        );
      }
      if (!downloadedIds.contains(p.id)) return null;
      if (online && downloadedUpdatedAt[p.id] != p.updatedAt) {
        return Tooltip(
          message: 'Atualização disponível',
          child: Icon(Icons.sync, size: 18, color: c.gr),
        );
      }
      return const DownloadStateIcon(state: DownloadState.baixada);
    }

    return RefreshIndicator(
      color: c.gr,
      onRefresh: () async {
        await ref.read(playlistSyncProvider.notifier).flush();
        ref.invalidate(serverPlaylistsProvider);
        await ref.read(serverPlaylistsProvider.future);
      },
      child: ListView(
        key: const PageStorageKey('library'),
        padding: AppLayout.screenPadding(context),
        children: [
          const ScreenTitle('Biblioteca'),
          const SyncNoticesBanner(),
          if (server.hasError && serverList.isEmpty)
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
              trailing: trailing(p),
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

/// "Nova playlist": com conta, vai para o servidor (na hora ou, sem
/// servidor, quando ele voltar); sem conta, fica só no aparelho.
Future<void> createPlaylist(BuildContext context, WidgetRef ref) async {
  final name = await showTextInputDialog(
    context,
    title: 'Nova playlist',
    hint: 'Nome da playlist',
    confirmLabel: 'Criar',
  );
  if (name == null || !context.mounted) return;
  if (!hasAccount(ref.read(sessionProvider))) {
    final p = await ref.read(localPlaylistsProvider.notifier).create(name);
    if (context.mounted) context.push(AppRoutes.localPlaylist(p.id));
    return;
  }
  try {
    final id = await ref.read(playlistEditorProvider).create(name);
    if (context.mounted) context.push(AppRoutes.playlist(id));
  } on ApiException catch (e) {
    if (context.mounted) AppToast.show(context, e.message);
  } on PlaylistConflict catch (e) {
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
