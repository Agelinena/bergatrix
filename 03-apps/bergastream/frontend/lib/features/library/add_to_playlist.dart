import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_error.dart';
import '../../core/theme/berga_colors.dart';
import '../../core/theme/berga_sizes.dart';
import '../../core/theme/berga_text.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/search_result.dart';
import '../../data/models/playlist_models.dart';
import '../../data/repositories/playlist_repository.dart';
import 'library_providers.dart';

/// "Adicionar à playlist" (⋮) e "Adicionar músicas à playlist" (link
/// importado): pergunta em qual playlist (ou cria uma) e adiciona no
/// servidor. Em lote, o servidor baixa as faixas em segundo plano.
Future<void> addToPlaylist(
  BuildContext context,
  WidgetRef ref, {
  required List<SearchResult> tracks,
  String? suggestedName,
}) async {
  final repo = ref.read(playlistRepositoryProvider);
  final target = await _choosePlaylist(context, repo, suggestedName);
  if (target == null || !context.mounted) return;
  ref.invalidate(myPlaylistsProvider);
  try {
    if (tracks.length == 1) {
      await repo.addTrack(target.id, tracks.single);
      if (context.mounted) {
        AppToast.show(context, 'Adicionada a ${target.name}');
      }
    } else {
      await repo.addTracks(target.id, tracks);
      if (context.mounted) {
        AppToast.show(
          context,
          '${tracks.length} músicas adicionadas a ${target.name}',
        );
      }
    }
  } on ApiException catch (e) {
    if (context.mounted) AppToast.show(context, e.message);
  }
}

Future<ServerPlaylist?> _choosePlaylist(
  BuildContext context,
  PlaylistRepository repo,
  String? suggestedName,
) {
  final c = BergaColors.of(context);
  return showModalBottomSheet<ServerPlaylist>(
    context: context,
    // Por cima da barra de navegação e do mini player (como no protótipo).
    useRootNavigator: true,
    backgroundColor: c.card,
    barrierColor: c.scrim,
    elevation: 0,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(BergaSizes.sheetRadius),
      ),
    ),
    builder: (sheetContext) =>
        _PlaylistPicker(repo: repo, suggestedName: suggestedName),
  );
}

class _PlaylistPicker extends StatelessWidget {
  const _PlaylistPicker({required this.repo, this.suggestedName});

  final PlaylistRepository repo;
  final String? suggestedName;

  Future<void> _create(BuildContext context) async {
    final name = await showTextInputDialog(
      context,
      title: 'Nova playlist',
      hint: 'Nome da playlist',
      initial: suggestedName ?? '',
      confirmLabel: 'Criar',
    );
    if (name == null || !context.mounted) return;
    try {
      final playlist = await repo.create(name);
      if (context.mounted) Navigator.of(context).pop(playlist);
    } on ApiException catch (e) {
      if (context.mounted) AppToast.show(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = BergaColors.of(context);
    Widget row({
      required Widget leading,
      required String label,
      required VoidCallback onTap,
    }) => GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          vertical: BergaSizes.trackPaddingVertical,
        ),
        child: Row(
          spacing: BergaSizes.trackGap,
          children: [
            leading,
            Expanded(
              child: Text(
                label,
                style: BergaText.trackTitle.copyWith(color: c.tx),
              ),
            ),
          ],
        ),
      ),
    );

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
        child: Padding(
          padding: BergaSizes.sheetPadding,
          child: FutureBuilder<List<ServerPlaylist>>(
            future: repo.myPlaylists(),
            builder: (context, snapshot) {
              // Só as que o usuário pode editar.
              final playlists = [
                for (final p in snapshot.data ?? const <ServerPlaylist>[])
                  if (p.playlistRole.canEdit) p,
              ];
              return ListView(
                shrinkWrap: true,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      'Adicionar à playlist',
                      style: BergaText.h2.copyWith(color: c.tx),
                    ),
                  ),
                  row(
                    leading: Container(
                      width: BergaSizes.trackCover,
                      height: BergaSizes.trackCover,
                      decoration: BoxDecoration(
                        color: c.ac,
                        borderRadius: BorderRadius.circular(
                          BergaSizes.coverRadius,
                        ),
                      ),
                      child: Icon(Icons.add, color: c.on),
                    ),
                    label: 'Nova playlist',
                    onTap: () => _create(context),
                  ),
                  if (snapshot.connectionState != ConnectionState.done)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Center(
                        child: SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: c.gr,
                          ),
                        ),
                      ),
                    )
                  else if (snapshot.hasError)
                    Text(
                      snapshot.error is ApiException
                          ? (snapshot.error! as ApiException).message
                          : 'Não foi possível carregar as playlists.',
                      style: BergaText.secondary.copyWith(color: c.mu),
                    ),
                  for (final p in playlists)
                    row(
                      leading: const Cover.playlist(
                        size: BergaSizes.trackCover,
                      ),
                      label: p.name,
                      onTap: () => Navigator.of(context).pop(p),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
