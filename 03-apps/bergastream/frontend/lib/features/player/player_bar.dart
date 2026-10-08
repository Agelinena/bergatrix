import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/berga_colors.dart';
import '../../core/theme/berga_text.dart';
import '../../core/widgets/widgets.dart';
import 'play_queue.dart';
import 'player_controller.dart';
import 'player_texts.dart';
import 'seek_bar.dart';

/// Painel da fila aberto no layout de navegador.
final desktopQueueOpenProvider = NotifierProvider<DesktopQueueOpen, bool>(
  DesktopQueueOpen.new,
);

class DesktopQueueOpen extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() {
    state = !state;
    if (state) ref.read(desktopLyricsOpenProvider.notifier).close();
  }

  void close() => state = false;
}

/// Painel da letra aberto no layout de navegador (um painel por vez).
final desktopLyricsOpenProvider = NotifierProvider<DesktopLyricsOpen, bool>(
  DesktopLyricsOpen.new,
);

class DesktopLyricsOpen extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() {
    state = !state;
    if (state) ref.read(desktopQueueOpenProvider.notifier).close();
  }

  void close() => state = false;
}

/// Barra do player no layout de navegador (Seção 6.8): faixa à esquerda,
/// controles e progresso no centro, fila à direita.
class PlayerBar extends ConsumerWidget {
  const PlayerBar({super.key});

  static const height = 84.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = BergaColors.of(context);
    final state = ref.watch(playerProvider);
    final item = state.current;
    if (item == null) return const SizedBox.shrink();
    final track = item.track;
    final controller = ref.read(playerProvider.notifier);
    final queueOpen = ref.watch(desktopQueueOpenProvider);
    final lyricsOpen = ref.watch(desktopLyricsOpenProvider);

    Widget control(
      IconData icon,
      String tooltip,
      VoidCallback onPressed, {
      bool active = false,
    }) => IconButton(
      onPressed: onPressed,
      icon: Icon(icon),
      iconSize: 22,
      color: active ? c.gr : c.mu,
      tooltip: tooltip,
    );

    return Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: c.bg,
        border: Border(top: BorderSide(color: c.card)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Row(
              spacing: 12,
              children: [
                Cover(
                  seed: track.id,
                  title: track.title,
                  size: 56,
                  image: coverImage(track),
                ),
                Flexible(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
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
              ],
            ),
          ),
          SizedBox(
            width: 520,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  spacing: 8,
                  children: [
                    control(
                      Icons.shuffle,
                      'Aleatório',
                      controller.toggleShuffle,
                      active: state.shuffle,
                    ),
                    control(
                      Icons.skip_previous,
                      'Anterior',
                      controller.previous,
                    ),
                    PlayButton(
                      playing: state.isPlaying,
                      onPressed: controller.togglePlay,
                    ),
                    control(Icons.skip_next, 'Próxima', controller.next),
                    control(
                      state.repeat == PlayerRepeat.umaFaixa
                          ? Icons.repeat_one
                          : Icons.repeat,
                      'Repetir',
                      controller.cycleRepeat,
                      active: state.repeat != PlayerRepeat.desligado,
                    ),
                  ],
                ),
                const SeekBar(height: 4, timesBelow: false),
              ],
            ),
          ),
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  control(
                    Icons.lyrics_outlined,
                    'Letra',
                    ref.read(desktopLyricsOpenProvider.notifier).toggle,
                    active: lyricsOpen,
                  ),
                  control(
                    Icons.queue_music,
                    'Fila',
                    ref.read(desktopQueueOpenProvider.notifier).toggle,
                    active: queueOpen,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
