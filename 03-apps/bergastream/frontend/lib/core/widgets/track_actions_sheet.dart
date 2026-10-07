import 'package:flutter/material.dart';

import '../theme/berga_colors.dart';
import '../theme/berga_sizes.dart';
import '../theme/berga_text.dart';
import 'app_toast.dart';
import 'cover.dart';

/// Folha inferior de ações da faixa (botão ⋮).
///
/// Ação com callback nulo aparece desabilitada (cor `mu`); ao tocar nela a
/// folha fecha e, se houver, mostra [disabledMessage] em um aviso rápido.
class TrackActionsSheet extends StatelessWidget {
  const TrackActionsSheet({
    super.key,
    required this.id,
    required this.title,
    required this.artist,
    this.cover,
    this.onShare,
    this.onAddToPlaylist,
    this.onAddToQueue,
    this.onGoToAlbum,
    this.onGoToArtist,
    this.disabledMessage,
    this.extraActions = const [],
    this.trackActions = true,
  });

  final String id;
  final String title;
  final String artist;
  final ImageProvider? cover;
  final VoidCallback? onShare;
  final VoidCallback? onAddToPlaylist;
  final VoidCallback? onAddToQueue;
  final VoidCallback? onGoToAlbum;
  final VoidCallback? onGoToArtist;
  final String? disabledMessage;

  /// Ações a mais no fim da folha (ex.: "Remover desta playlist").
  final List<(String, VoidCallback)> extraActions;

  /// Mostra as 5 ações de faixa (Compartilhar … Ir para o artista).
  final bool trackActions;

  /// Com [hideTrackActions], mostra só o cabeçalho e as [extraActions]
  /// (menu da playlist, por exemplo).
  static Future<void> show(
    BuildContext context,
    TrackActionsSheet sheet, {
    bool hideTrackActions = false,
  }) {
    final c = BergaColors.of(context);
    return showModalBottomSheet<void>(
      context: context,
      // Por cima da barra de navegação e do mini player (como no protótipo).
      useRootNavigator: true,
      backgroundColor: c.card,
      barrierColor: c.scrim,
      elevation: 0,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(BergaSizes.sheetRadius),
        ),
      ),
      builder: (_) => hideTrackActions
          ? TrackActionsSheet(
              id: sheet.id,
              title: sheet.title,
              artist: sheet.artist,
              cover: sheet.cover,
              extraActions: sheet.extraActions,
              disabledMessage: sheet.disabledMessage,
              trackActions: false,
            )
          : sheet,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = BergaColors.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: BergaSizes.sheetPadding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                spacing: 10,
                children: [
                  Cover(
                    seed: id,
                    title: title,
                    size: BergaSizes.trackCover,
                    image: cover,
                  ),
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
                          artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: BergaText.secondary.copyWith(color: c.mu),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (trackActions) ...[
              _item(context, 'Compartilhar', onShare),
              _item(context, 'Adicionar à playlist', onAddToPlaylist),
              _item(context, 'Adicionar à fila', onAddToQueue),
              _item(context, 'Ir para o álbum', onGoToAlbum),
              _item(context, 'Ir para o artista', onGoToArtist),
            ],
            for (final (label, action) in extraActions)
              _item(context, label, action),
          ],
        ),
      ),
    );
  }

  Widget _item(BuildContext context, String label, VoidCallback? action) {
    final c = BergaColors.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (action == null && disabledMessage != null) {
          AppToast.show(context, disabledMessage!);
        }
        Navigator.of(context).pop();
        action?.call();
      },
      child: SizedBox(
        width: double.infinity,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            vertical: BergaSizes.sheetItemPaddingVertical,
          ),
          child: Text(
            label,
            style: BergaText.body.copyWith(color: action == null ? c.mu : c.tx),
          ),
        ),
      ),
    );
  }
}
