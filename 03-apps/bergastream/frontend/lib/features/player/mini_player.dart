import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/berga_colors.dart';
import '../../core/theme/berga_sizes.dart';
import '../../core/theme/berga_text.dart';
import '../../core/widgets/widgets.dart';
import 'full_player.dart';
import 'player_controller.dart';
import 'player_texts.dart';
import 'seek_bar.dart';

/// Mini player flutuante (Seção 6.6). Só aparece com faixa carregada; tocar
/// nele abre o player grande. Enquanto o servidor prepara a faixa mostra
/// "Baixando…" (Seção 7.3). Arrastar para a esquerda pula para a próxima;
/// para a direita, volta para a anterior.
class MiniPlayer extends ConsumerStatefulWidget {
  const MiniPlayer({super.key});

  /// Arraste mínimo (ou um gesto rápido) para trocar de música.
  static const swipeDistance = 80.0;
  static const swipeVelocity = 800.0;

  @override
  ConsumerState<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends ConsumerState<MiniPlayer> {
  double _dx = 0;
  bool _dragging = false;

  void _end(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    final controller = ref.read(playerProvider.notifier);
    if (_dx <= -MiniPlayer.swipeDistance ||
        velocity <= -MiniPlayer.swipeVelocity) {
      unawaited(controller.next());
    } else if (_dx >= MiniPlayer.swipeDistance ||
        velocity >= MiniPlayer.swipeVelocity) {
      unawaited(controller.previous(track: true));
    }
    setState(() {
      _dx = 0;
      _dragging = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = BergaColors.of(context);
    final state = ref.watch(playerProvider);
    final item = state.current;
    if (item == null) return const SizedBox.shrink();
    final track = item.track;
    final position = ref.watch(playerPositionProvider).value ?? Duration.zero;

    return GestureDetector(
      onTap: () => openFullPlayer(context),
      onHorizontalDragStart: (_) => setState(() => _dragging = true),
      onHorizontalDragUpdate: (d) =>
          setState(() => _dx = (_dx + d.delta.dx).clamp(-160.0, 160.0)),
      onHorizontalDragEnd: _end,
      onHorizontalDragCancel: () => setState(() {
        _dx = 0;
        _dragging = false;
      }),
      child: AnimatedContainer(
        duration: _dragging ? Duration.zero : const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        transform: Matrix4.translationValues(_dx, 0, 0),
        child: Opacity(
          opacity: (1 - _dx.abs() / 320).clamp(0.4, 1.0),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
            decoration: BoxDecoration(
              color: c.card,
              borderRadius: BorderRadius.circular(BergaSizes.cardRadius),
              boxShadow: const [
                BoxShadow(
                  offset: Offset(0, 6),
                  blurRadius: 22,
                  color: Color(0x66000000),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  spacing: 10,
                  children: [
                    Cover(
                      seed: track.id,
                      title: track.title,
                      size: 40,
                      image: coverImage(track),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: BergaText.trackTitle.copyWith(color: c.tx),
                          ),
                          Text(
                            state.isPreparing
                                ? 'Baixando…'
                                : artistAndAlbum(track),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: BergaText.secondary.copyWith(
                              color: state.isPreparing ? c.gr : c.mu,
                            ),
                          ),
                        ],
                      ),
                    ),
                    PlayButton(
                      playing: state.isPlaying,
                      onPressed: ref.read(playerProvider.notifier).togglePlay,
                    ),
                  ],
                ),
                const SizedBox(height: 7),
                ProgressBarThin(value: playedFraction(state, position)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
