import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/routes.dart';
import '../../core/network/api_error.dart';
import '../../core/theme/berga_colors.dart';
import '../../core/theme/berga_sizes.dart';
import '../../core/theme/berga_text.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/search_full.dart';
import '../../data/models/search_result.dart';
import '../../data/models/playlist_models.dart';
import '../playlists/playlist_store.dart';

/// "Adicionar à playlist" (⋮) e "Adicionar músicas à playlist" (link
/// importado): pergunta em qual playlist (ou cria uma) e adiciona. Sem
/// servidor, a alteração fica no aparelho e vai quando ele voltar.
Future<void> addToPlaylist(
  BuildContext context,
  WidgetRef ref, {
  required List<SearchResult> tracks,
  String? suggestedName,
}) async {
  final target = await _choosePlaylist(context, suggestedName);
  if (target == null || !context.mounted) return;
  try {
    await ref.read(playlistEditorProvider).addTracks(target.id, tracks);
    if (context.mounted) {
      AppToast.show(
        context,
        tracks.length == 1
            ? 'Adicionada a ${target.name}'
            : '${tracks.length} músicas adicionadas a ${target.name}',
      );
    }
  } on ApiException catch (e) {
    if (context.mounted) AppToast.show(context, e.message);
  } on PlaylistConflict catch (e) {
    if (context.mounted) AppToast.show(context, e.message);
  }
}

/// Escolhida: id (ou ref temporário) e nome.
typedef _Target = ({String id, String name});

Future<_Target?> _choosePlaylist(BuildContext context, String? suggestedName) {
  final c = BergaColors.of(context);
  return showModalBottomSheet<_Target>(
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
    builder: (sheetContext) => _PlaylistPicker(suggestedName: suggestedName),
  );
}

class _PlaylistPicker extends ConsumerWidget {
  const _PlaylistPicker({this.suggestedName});

  final String? suggestedName;

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final name = await showTextInputDialog(
      context,
      title: 'Nova playlist',
      hint: 'Nome da playlist',
      initial: suggestedName ?? '',
      confirmLabel: 'Criar',
    );
    if (name == null || !context.mounted) return;
    try {
      final id = await ref.read(playlistEditorProvider).create(name);
      if (context.mounted) Navigator.of(context).pop((id: id, name: name));
    } on ApiException catch (e) {
      if (context.mounted) AppToast.show(context, e.message);
    } on PlaylistConflict catch (e) {
      if (context.mounted) AppToast.show(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = BergaColors.of(context);
    final snapshot = ref.watch(myPlaylistsProvider);
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
          child: Builder(
            builder: (context) {
              // Só as que o usuário pode editar.
              final playlists = [
                for (final p in snapshot.value ?? const <ServerPlaylist>[])
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
                    onTap: () => _create(context, ref),
                  ),
                  if (snapshot.isLoading && !snapshot.hasValue)
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
                      onTap: () =>
                          Navigator.of(context).pop((id: p.id, name: p.name)),
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

/// "Importar" um link de playlist ou álbum: pergunta se cria uma playlist
/// nova com todos os dados da original (nome, descrição e foto de capa) ou
/// se só adiciona as músicas a uma playlist escolhida.
Future<void> importLink(
  BuildContext context,
  WidgetRef ref,
  ResolvedLink link,
) async {
  if (link.isTrack) {
    return addToPlaylist(context, ref, tracks: link.tracks);
  }
  final n = link.tracks.length;
  final choice = await showChoiceDialog(
    context,
    message: 'Importar "${link.title}"?',
    detail:
        'Importar tudo cria uma playlist nova com o nome, a descrição e a '
        'foto de capa do ${link.sourceLabel}, e ${n == 1 ? 'a música' : 'as $n músicas'}. '
        'Ou escolha só as músicas para pôr numa playlist sua.',
    options: const ['Só as músicas', 'Importar tudo'],
  );
  if (!context.mounted || choice == null) return;
  if (choice == 0) {
    return addToPlaylist(
      context,
      ref,
      tracks: link.tracks,
      suggestedName: link.title,
    );
  }
  try {
    final id = await ref
        .read(playlistEditorProvider)
        .importPlaylist(
          name: link.title,
          description: link.description,
          coverUrl: link.coverUrl,
          tracks: link.tracks,
        );
    if (!context.mounted) return;
    AppToast.show(
      context,
      n == 1
          ? 'Playlist "${link.title}" importada'
          : 'Playlist "${link.title}" importada com $n músicas',
    );
    context.push(AppRoutes.playlist(id));
  } on ApiException catch (e) {
    if (context.mounted) AppToast.show(context, e.message);
  } on PlaylistConflict catch (e) {
    if (context.mounted) AppToast.show(context, e.message);
  }
}
