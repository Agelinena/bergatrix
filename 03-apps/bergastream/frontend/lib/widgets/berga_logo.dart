import 'dart:math' as math;
import 'package:flutter/material.dart';

/// BergaStream logo rendered via CustomPainter — no image asset required,
/// pixel-perfect at any size, works on every platform.
///
/// Usage:
///   BergaLogo(size: 64)                         // icon only
///   BergaLogo(size: 48, showWordmark: true)      // icon + "bergastream" text
class BergaLogo extends StatelessWidget {
  final double size;
  final bool showWordmark;

  const BergaLogo({super.key, this.size = 48, this.showWordmark = false});

  @override
  Widget build(BuildContext context) {
    if (!showWordmark) {
      return SizedBox(
        width: size,
        height: size,
        child: CustomPaint(painter: _LogoIconPainter()),
      );
    }

    // Icon + text side-by-side
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: size,
          height: size,
          child: CustomPaint(painter: _LogoIconPainter()),
        ),
        SizedBox(width: size * 0.22),
        RichText(
          text: TextSpan(
            style: TextStyle(
              fontSize: size * 0.55,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
              height: 1,
            ),
            children: const [
              TextSpan(text: 'berga', style: TextStyle(color: Colors.white)),
              TextSpan(
                  text: 'stream',
                  style: TextStyle(color: Color(0xFF1DB954))),
            ],
          ),
        ),
      ],
    );
  }
}

class _LogoIconPainter extends CustomPainter {
  static const _green = Color(0xFF1DB954);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width; // treat as square
    final bgRadius = s * 0.219; // ~112/512

    // ── Background rounded square ─────────────────────────────────────────
    final bgPaint = Paint()..color = _green;
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, s, s), Radius.circular(bgRadius)),
      bgPaint,
    );

    // ── Equalizer bars ────────────────────────────────────────────────────
    // Geometry based on 512×512 master (scale to `s`):
    //   barW=40, gap=20, 5 bars → total=280, startX=116, centreY=256
    //   heights: 96, 176, 272, 176, 96
    final barPaint = Paint()..color = Colors.black;
    final sc = s / 512.0;

    const startX = 116.0;
    const barW = 40.0;
    const gap = 20.0;
    const centreY = 256.0;
    const heights = [96.0, 176.0, 272.0, 176.0, 96.0];

    for (int i = 0; i < 5; i++) {
      final x = (startX + i * (barW + gap)) * sc;
      final h = heights[i] * sc;
      final y = (centreY - heights[i] / 2) * sc;
      final r = math.min(barW * sc / 2, h / 2); // pill radius

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, y, barW * sc, h),
          Radius.circular(r),
        ),
        barPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
