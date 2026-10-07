import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/berga_colors.dart';
import '../../core/theme/berga_sizes.dart';
import '../../core/theme/berga_text.dart';
import '../../core/utils/format.dart';
import '../../core/widgets/widgets.dart';
import 'player_controller.dart';

/// Duração conhecida da faixa atual: a do áudio carregado ou, antes disso,
/// a dos metadados.
Duration? currentDuration(PlayerState state) {
  if (state.duration != null && state.duration! > Duration.zero) {
    return state.duration;
  }
  final seconds = state.current?.track.durationSeconds ?? 0;
  return seconds > 0 ? Duration(seconds: seconds) : null;
}

/// Fração tocada (0 a 1) da faixa atual.
double playedFraction(PlayerState state, Duration position) {
  final duration = currentDuration(state);
  if (duration == null || duration == Duration.zero) return 0;
  return (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
}

/// Barra de progresso arrastável (player grande e barra do navegador).
/// [timesBelow]: tempos embaixo (celular) ou dos lados (navegador).
class SeekBar extends ConsumerStatefulWidget {
  const SeekBar({
    super.key,
    this.height = BergaSizes.progressHeightLarge,
    this.timesBelow = true,
  });

  final double height;
  final bool timesBelow;

  @override
  ConsumerState<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends ConsumerState<SeekBar> {
  /// Posição enquanto o dedo arrasta (só busca ao soltar).
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final c = BergaColors.of(context);
    final state = ref.watch(playerProvider);
    final position = ref.watch(playerPositionProvider).value ?? Duration.zero;
    final duration = currentDuration(state);
    final fraction = _dragging ?? playedFraction(state, position);
    final shown = duration == null ? position : duration * fraction;
    final controller = ref.read(playerProvider.notifier);
    final times = BergaText.secondary.copyWith(color: c.mu, fontSize: 12);

    final bar = LayoutBuilder(
      builder: (context, constraints) {
        double at(Offset local) =>
            (local.dx / constraints.maxWidth).clamp(0.0, 1.0);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) => controller.seekFraction(at(d.localPosition)),
          onHorizontalDragStart: (d) =>
              setState(() => _dragging = at(d.localPosition)),
          onHorizontalDragUpdate: (d) =>
              setState(() => _dragging = at(d.localPosition)),
          onHorizontalDragEnd: (_) {
            final target = _dragging;
            setState(() => _dragging = null);
            if (target != null) controller.seekFraction(target);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: ProgressBarThin(value: fraction, height: widget.height),
          ),
        );
      },
    );

    final elapsed = Text(formatDuration(shown.inSeconds), style: times);
    final total = Text(
      duration == null ? '--:--' : formatDuration(duration.inSeconds),
      style: times,
    );

    if (widget.timesBelow) {
      return Column(
        children: [
          bar,
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [elapsed, total],
          ),
        ],
      );
    }
    return Row(
      spacing: 8,
      children: [
        elapsed,
        Expanded(child: bar),
        total,
      ],
    );
  }
}
