import 'package:flutter/material.dart';

import '../theme/berga_colors.dart';
import '../theme/berga_sizes.dart';
import '../theme/berga_text.dart';

/// Chip em pílula. Ativo = fundo laranja, texto `on`, peso 600.
class AppChip extends StatelessWidget {
  const AppChip({
    super.key,
    required this.label,
    this.active = false,
    this.icon,
    this.onTap,
    this.leading,
    this.iconColor,
  });

  final String label;
  final bool active;
  final IconData? icon;

  /// No lugar do ícone (ex.: anel de progresso).
  final Widget? leading;
  final Color? iconColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = BergaColors.of(context);
    final foreground = active ? c.on : c.tx;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: BergaSizes.chipPadding,
        decoration: ShapeDecoration(
          color: active ? c.ac : c.card,
          shape: const StadiumBorder(),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 4,
          children: [
            ?leading,
            if (icon != null)
              Icon(icon, size: 15, color: iconColor ?? foreground),
            // Rótulos longos quebram em até 2 linhas (telas de 360 px).
            Flexible(
              child: Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: (active ? BergaText.chipActive : BergaText.chip)
                    .copyWith(color: foreground),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Botão principal laranja em pílula. Com [expanded], ocupa a largura toda.
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.expanded = false,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final c = BergaColors.of(context);
    return Semantics(
      button: true,
      child: GestureDetector(
        onTap: onPressed,
        child: Container(
          padding: BergaSizes.buttonPadding,
          decoration: ShapeDecoration(
            color: c.ac,
            shape: const StadiumBorder(),
          ),
          child: Row(
            mainAxisSize: expanded ? MainAxisSize.max : MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            spacing: 6,
            children: [
              if (icon != null) Icon(icon, size: 18, color: c.on),
              Text(label, style: BergaText.button.copyWith(color: c.on)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Botão circular laranja de play/pause (38 no mini player e na playlist,
/// 60 no player grande).
class PlayButton extends StatelessWidget {
  const PlayButton({
    super.key,
    required this.playing,
    this.size = BergaSizes.playButton,
    this.onPressed,
  });

  final bool playing;
  final double size;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final c = BergaColors.of(context);
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: c.ac, shape: BoxShape.circle),
        child: Icon(
          playing ? Icons.pause : Icons.play_arrow,
          size: size * 0.55,
          color: c.on,
          semanticLabel: playing ? 'Pausar' : 'Tocar',
        ),
      ),
    );
  }
}
