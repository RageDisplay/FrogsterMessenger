/// Frogster's mark: a lily pad, drawn geometrically -- a disc with a wedge
/// cut out towards the upper right, and a dot where a frog would sit.
library;

import 'package:flutter/material.dart';

import '../theme/pond_colors.dart';

class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 32, this.color});

  final double size;

  /// Defaults to the theme accent.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Frogster',
      image: true,
      child: CustomPaint(
        size: Size.square(size),
        painter: _LilyPadPainter(color ?? context.pond.accent),
      ),
    );
  }
}

class _LilyPadPainter extends CustomPainter {
  const _LilyPadPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // Drawn on a 32-unit grid and scaled, matching the SVG in the design.
    final scale = size.width / 32;
    canvas.scale(scale);
    final paint = Paint()
      ..color = color
      ..isAntiAlias = true;

    final pad = Path()
      ..moveTo(16, 2)
      ..arcToPoint(const Offset(29.6, 19.3), radius: const Radius.circular(14), largeArc: true, clockwise: false)
      ..lineTo(16, 16)
      ..lineTo(25.8, 4.9)
      ..arcToPoint(const Offset(16, 2), radius: const Radius.circular(14), clockwise: false)
      ..close();
    canvas.drawPath(pad, paint);
    canvas.drawCircle(const Offset(20.5, 9.5), 1.6, paint);
  }

  @override
  bool shouldRepaint(_LilyPadPainter old) => old.color != color;
}
