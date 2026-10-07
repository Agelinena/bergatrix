import 'package:flutter/material.dart';

import '../theme/berga_colors.dart';
import '../theme/berga_sizes.dart';
import '../theme/berga_text.dart';
import 'cover.dart';
import 'download_state_icon.dart';

/// Linha de faixa (Seção 5.4): capa 46, título, artista (e "por Fulano") e ⋮.
class TrackRow extends StatelessWidget {
  const TrackRow({
    super.key,
    required this.id,
    required this.title,
    required this.artist,
    this.addedBy,
    this.playing = false,
    this.downloadState = DownloadState.naoBaixada,
    this.downloadProgress,
    this.cover,
    this.onTap,
    this.onMore,
    this.onQueue,
    this.number,
  });

  /// Id da faixa (também define a cor da capa sem imagem).
  final String id;
  final String title;
  final String artist;

  /// Quem adicionou a faixa à playlist (mostra " · por Fulano").
  final String? addedBy;

  /// Faixa tocando agora: título em verde.
  final bool playing;
  final DownloadState downloadState;
  final double? downloadProgress;
  final ImageProvider? cover;
  final VoidCallback? onTap;
  final VoidCallback? onMore;

  /// Arrastar a linha para o lado (qualquer direção) = adicionar à fila.
  /// A linha volta ao lugar (Seção 5.4).
  final VoidCallback? onQueue;

  /// Lista numerada (álbum): mostra o número no lugar da capa.
  final int? number;

  @override
  Widget build(BuildContext context) {
    final c = BergaColors.of(context);
    final subtitle = addedBy == null ? artist : '$artist · por $addedBy';

    final row = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          vertical: BergaSizes.trackPaddingVertical,
        ),
        child: Row(
          children: [
            if (number != null)
              SizedBox(
                width: 28,
                child: Text(
                  '$number',
                  textAlign: TextAlign.center,
                  style: BergaText.body.copyWith(color: playing ? c.gr : c.mu),
                ),
              )
            else
              Cover(
                seed: id,
                title: title,
                size: BergaSizes.trackCover,
                image: cover,
              ),
            const SizedBox(width: BergaSizes.trackGap),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: BergaText.trackTitle.copyWith(
                      color: playing ? c.gr : c.tx,
                    ),
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
            if (downloadState != DownloadState.naoBaixada) ...[
              const SizedBox(width: 8),
              DownloadStateIcon(
                state: downloadState,
                progress: downloadProgress,
              ),
            ],
            IconButton(
              onPressed: onMore,
              icon: const Icon(Icons.more_vert),
              color: c.mu,
              iconSize: 20,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 40, height: 40),
              tooltip: 'Mais opções',
            ),
          ],
        ),
      ),
    );
    if (onQueue == null) return row;

    Widget background(Alignment alignment) => Container(
      color: c.card,
      alignment: alignment,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 8,
        children: [
          Icon(Icons.queue_music, color: c.gr, size: 20),
          Text(
            'Adicionar à fila',
            style: BergaText.chipActive.copyWith(color: c.gr),
          ),
        ],
      ),
    );

    return Dismissible(
      key: ValueKey('fila-$id'),
      background: background(Alignment.centerLeft),
      secondaryBackground: background(Alignment.centerRight),
      confirmDismiss: (_) async {
        onQueue!();
        return false;
      },
      child: row,
    );
  }
}
