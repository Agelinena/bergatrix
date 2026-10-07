import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

    return _SwipeToQueue(onQueue: onQueue!, child: row);
  }
}

/// Arrastar a linha para o lado adiciona à fila. Pede um arraste de
/// verdade: passar de [threshold] da largura (no mínimo [minDistance]) e
/// soltar ainda depois do ponto. Um "peteleco" rápido no meio da rolagem
/// não conta (o `Dismissible` contava). Vibra ao passar do ponto.
class _SwipeToQueue extends StatefulWidget {
  const _SwipeToQueue({required this.onQueue, required this.child});

  final VoidCallback onQueue;
  final Widget child;

  static const threshold = 0.35;
  static const minDistance = 110.0;

  @override
  State<_SwipeToQueue> createState() => _SwipeToQueueState();
}

class _SwipeToQueueState extends State<_SwipeToQueue> {
  double _dx = 0;
  bool _dragging = false;
  bool _armed = false;

  double _limit(double width) =>
      (width * _SwipeToQueue.threshold).clamp(_SwipeToQueue.minDistance, width);

  @override
  Widget build(BuildContext context) {
    final c = BergaColors.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final limit = _limit(width);
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragStart: (_) => setState(() => _dragging = true),
          onHorizontalDragUpdate: (d) {
            final dx = (_dx + d.delta.dx).clamp(-width * 0.6, width * 0.6);
            final armed = dx.abs() >= limit;
            if (armed && !_armed) HapticFeedback.selectionClick();
            setState(() {
              _dx = dx;
              _armed = armed;
            });
          },
          onHorizontalDragEnd: (_) {
            if (_armed) widget.onQueue();
            setState(() {
              _dx = 0;
              _armed = false;
              _dragging = false;
            });
          },
          onHorizontalDragCancel: () => setState(() {
            _dx = 0;
            _armed = false;
            _dragging = false;
          }),
          child: Stack(
            children: [
              if (_dx != 0)
                Positioned.fill(
                  child: Container(
                    color: c.card,
                    alignment: _dx > 0
                        ? Alignment.centerLeft
                        : Alignment.centerRight,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      spacing: 8,
                      children: [
                        Icon(
                          Icons.queue_music,
                          color: _armed ? c.gr : c.mu,
                          size: 20,
                        ),
                        Text(
                          _armed ? 'Solte para adicionar' : 'Adicionar à fila',
                          style: BergaText.chipActive.copyWith(
                            color: _armed ? c.gr : c.mu,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              AnimatedContainer(
                duration: _dragging
                    ? Duration.zero
                    : const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                transform: Matrix4.translationValues(_dx, 0, 0),
                // Fundo da tela: o aviso de trás só aparece onde a linha saiu.
                child: ColoredBox(color: c.bg, child: widget.child),
              ),
            ],
          ),
        );
      },
    );
  }
}
