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
/// "Baixando…" (Seção 7.3).
class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = BergaColors.of(context);
    final state = ref.watch(playerProvider);
    final item = state.current;
    if (item == null) return const SizedBox.shrink();
    final track = item.track;
    final position = ref.watch(playerPositionProvider).value ?? Duration.zero;

    return GestureDetector(
      onTap: () => openFullPlayer(context),
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
                        state.isPreparing ? 'Baixando…' : artistAndAlbum(track),
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
    );
  }
}
