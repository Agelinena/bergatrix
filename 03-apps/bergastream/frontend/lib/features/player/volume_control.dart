import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/berga_colors.dart';
import '../settings/preferences.dart';
import 'player_controller.dart';

/// Volume do player (barra do computador e da web): ícone liga/desliga o
/// mudo, a barra ajusta. Fica guardado no aparelho.
class VolumeControl extends ConsumerStatefulWidget {
  const VolumeControl({super.key, this.width = 110, this.showSlider = true});

  final double width;

  /// Janela estreita: só o ícone (mudo).
  final bool showSlider;

  @override
  ConsumerState<VolumeControl> createState() => _VolumeControlState();
}

class _VolumeControlState extends ConsumerState<VolumeControl> {
  /// Volume antes do mudo (para voltar nele).
  double _beforeMute = 1;

  @override
  Widget build(BuildContext context) {
    final c = BergaColors.of(context);
    final volume = ref.watch(preferencesProvider.select((p) => p.volume));
    final player = ref.read(playerProvider.notifier);
    final icon = volume == 0
        ? Icons.volume_off
        : volume < 0.5
        ? Icons.volume_down
        : Icons.volume_up;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          onPressed: () {
            if (volume > 0) {
              _beforeMute = volume;
              player.setVolume(0);
            } else {
              player.setVolume(_beforeMute > 0 ? _beforeMute : 1);
            }
          },
          icon: Icon(icon),
          iconSize: 20,
          color: c.mu,
          tooltip: volume == 0 ? 'Tirar do mudo' : 'Mudo',
        ),
        if (widget.showSlider)
          SizedBox(
            width: widget.width,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                activeTrackColor: c.gr,
                inactiveTrackColor: c.track,
                thumbColor: c.tx,
              ),
              child: Slider(
                value: volume,
                semanticFormatterCallback: (v) =>
                    'Volume ${(v * 100).round()}%',
                onChanged: (v) => player.setVolume(v, save: false),
                onChangeEnd: (v) => player.setVolume(v),
              ),
            ),
          ),
      ],
    );
  }
}
