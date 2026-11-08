import 'package:flutter/material.dart';

/// Reusable Google Gemini-style AI sparkle vector logo.
/// Renders razor-sharp vector geometry with a vibrant gradient
/// and a transparent background at any resolution.
class AiSparkleIcon extends StatelessWidget {
  final double size;
  final Color? fallbackColor;

  const AiSparkleIcon({
    super.key,
    this.size = 24.0,
    this.fallbackColor,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        size: Size(size, size),
        painter: const _AiSparklePainter(),
      ),
    );
  }
}

class _AiSparklePainter extends CustomPainter {
  const _AiSparklePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final rect = Offset.zero & size;

    // Google Gemini iconic rainbow gradient
    final gradient = const LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        Color(0xFF4285F4), // Google Blue
        Color(0xFF9C27B0), // Purple / Magenta
        Color(0xFFEA4335), // Red / Coral
        Color(0xFFFBBC05), // Yellow / Amber
        Color(0xFF34A853), // Green
      ],
      stops: [0.0, 0.30, 0.55, 0.80, 1.0],
    ).createShader(rect);

    final paint = Paint()
      ..shader = gradient
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    // 1. Primary 4-pointed sparkle star (centered, scaled)
    final mainScale = 0.84;
    final mw = w * mainScale;
    final mh = h * mainScale;
    final mx0 = 0.0;
    final my0 = h * (1.0 - mainScale);
    final mcx = mx0 + mw / 2;
    final mcy = my0 + mh / 2;

    final mainPath = Path()
      ..moveTo(mcx, my0)
      ..quadraticBezierTo(mcx, mcy, mx0 + mw, mcy)
      ..quadraticBezierTo(mcx, mcy, mcx, my0 + mh)
      ..quadraticBezierTo(mcx, mcy, mx0, mcy)
      ..quadraticBezierTo(mcx, mcy, mcx, my0)
      ..close();

    canvas.drawPath(mainPath, paint);

    // 2. Secondary small sparkle star at top-right
    final sw = w * 0.32;
    final sh = h * 0.32;
    final sx0 = w - sw;
    final sy0 = 0.0;
    final scx = sx0 + sw / 2;
    final scy = sy0 + sh / 2;

    final secPath = Path()
      ..moveTo(scx, sy0)
      ..quadraticBezierTo(scx, scy, sx0 + sw, scy)
      ..quadraticBezierTo(scx, scy, scx, sy0 + sh)
      ..quadraticBezierTo(scx, scy, sx0, scy)
      ..quadraticBezierTo(scx, scy, scx, sy0)
      ..close();

    canvas.drawPath(secPath, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
