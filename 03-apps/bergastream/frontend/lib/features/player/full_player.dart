import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/berga_colors.dart';
import '../../core/theme/berga_sizes.dart';
import '../../core/theme/berga_text.dart';
import '../../core/widgets/widgets.dart';
import '../../app/catalog_navigation.dart';
import 'play_queue.dart';
import 'player_controller.dart';
import 'player_texts.dart';
import 'queue_panel.dart';
import 'seek_bar.dart';
import 'track_menu.dart';

/// Abre o player grande subindo de baixo em 280 ms (Seção 6.1).
Future<void> openFullPlayer(BuildContext context) {
  return Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder<void>(
      transitionDuration: const Duration(milliseconds: 280),
      reverseTransitionDuration: const Duration(milliseconds: 280),
      pageBuilder: (_, _, _) => const FullPlayer(),
      transitionsBuilder: (_, animation, _, child) => SlideTransition(
        position: Tween(
          begin: const Offset(0, 1),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOut)),
        child: child,
      ),
    ),
  );
}

/// Player grande (Seção 6.6).
class FullPlayer extends ConsumerStatefulWidget {
  const FullPlayer({super.key});

  @override
  ConsumerState<FullPlayer> createState() => _FullPlayerState();
}

class _FullPlayerState extends ConsumerState<FullPlayer> {
  bool _showQueue = false;

  @override
  Widget build(BuildContext context) {
    final c = BergaColors.of(context);
    final state = ref.watch(playerProvider);
    final controller = ref.read(playerProvider.notifier);
    final item = state.current;

    // A fila pode esvaziar com o player aberto (ex.: sair).
    if (item == null) {
      return Scaffold(
        body: Center(
          child: Text(
            'Nada tocando',
            style: BergaText.body.copyWith(color: c.mu),
          ),
        ),
      );
    }
    final track = item.track;

    Widget control(
      IconData icon,
      String tooltip,
      VoidCallback onPressed, {
      bool active = false,
    }) => IconButton(
      onPressed: onPressed,
      icon: Icon(icon),
      iconSize: 26,
      color: active ? c.gr : c.tx,
      tooltip: tooltip,
    );

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 22),
          children: [
            Row(
              children: [
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.keyboard_arrow_down),
                  iconSize: 28,
                  color: c.tx,
                  tooltip: 'Fechar',
                ),
                Expanded(
                  child: Text(
                    'Tocando de ${state.context ?? 'Busca'}',
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: BergaText.secondary.copyWith(color: c.mu),
                  ),
                ),
                IconButton(
                  onPressed: () {
                    // Fecha o player e navega com o router capturado antes
                    // (o context do player some ao fechar).
                    final router = GoRouter.of(context);
                    VoidCallback? closeThen(String? path) => path == null
                        ? null
                        : () {
                            Navigator.of(context).pop();
                            router.push(path);
                          };
                    showTrackMenu(
                      context,
                      ref,
                      track,
                      onGoToAlbum: closeThen(albumPathOf(context, track)),
                      onGoToArtist: closeThen(artistPathOf(context, track)),
                    );
                  },
                  icon: const Icon(Icons.more_vert),
                  color: c.tx,
                  tooltip: 'Mais opções',
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(top: 14, bottom: 20),
              child: LayoutBuilder(
                builder: (context, constraints) => Cover(
                  seed: track.id,
                  title: track.title,
                  size: constraints.maxWidth,
                  radius: BergaSizes.playerCoverRadius,
                  initialSize: 70,
                  image: coverImage(track),
                ),
              ),
            ),
            ScreenTitle(track.title, bottom: 2),
            Text(
              state.isPreparing ? 'Baixando…' : artistAndAlbum(track),
              style: BergaText.secondary.copyWith(
                color: state.isPreparing ? c.gr : c.mu,
              ),
            ),
            const SizedBox(height: 10),
            const SeekBar(),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  control(
                    Icons.shuffle,
                    'Aleatório',
                    controller.toggleShuffle,
                    active: state.shuffle,
                  ),
                  control(Icons.skip_previous, 'Anterior', controller.previous),
                  PlayButton(
                    playing: state.isPlaying,
                    size: BergaSizes.playButtonLarge,
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
                  control(
                    Icons.queue_music,
                    'Fila',
                    () => setState(() => _showQueue = !_showQueue),
                    active: _showQueue,
                  ),
                ],
              ),
            ),
            if (_showQueue) const QueuePanel(),
          ],
        ),
      ),
    );
  }
}
