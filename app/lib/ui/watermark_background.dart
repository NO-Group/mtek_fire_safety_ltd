import 'package:flutter/material.dart';

import '../core/theme.dart';

/// Faint brand watermark behind the app UI (owner request, 2026-08-29) —
/// a tiled, rotated "M-TEK FIRE & SAFETY LTD." pattern at ~3.5% ink,
/// matching the document watermarks. Purely decorative: wrapped in
/// IgnorePointer so it never intercepts touches.
class WatermarkBackground extends StatelessWidget {
  const WatermarkBackground({super.key});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        size: Size.infinite,
        painter: _WatermarkPainter(),
      ),
    );
  }
}

class _WatermarkPainter extends CustomPainter {
  static final TextPainter _sample = _tilePainter();

  static TextPainter _tilePainter() {
    return TextPainter(
      text: const TextSpan(text: 'M-TEK FIRE & SAFETY LTD.'),
      textDirection: TextDirection.ltr,
    )..layout();
  }

  @override
  void paint(Canvas canvas, Size size) {
    const tileW = 300.0, tileH = 210.0;
    canvas.saveLayer(null, Paint());
    for (var y = -tileH; y < size.height + tileH; y += tileH) {
      for (var x = -tileW; x < size.width + tileW; x += tileW) {
        canvas.save();
        canvas.translate(x + tileW / 2, y + tileH / 2);
        canvas.rotate(-0.32);
        _sample.paint(canvas, const Offset(-70, -8));
        canvas.restore();
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Ink used by the watermark (kept here so theme stays single-source).
const Color watermarkInk = Color(0x090A1220); // ~3.5% navy
