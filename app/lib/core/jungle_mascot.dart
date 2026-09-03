import 'package:flutter/material.dart';

/// The JungleChat mascot: a cartoon head in "thinking" pose.
/// Dark-theme world, light-skinned figure, subtle thought bubble.
/// Pure vector (CustomPainter) — zero image assets, scales to any size,
/// cheap to draw on low-end devices. Also rendered to PNG at 1024px by
/// test/render_mascot_icon.dart for the launcher icon.
class JungleMascot extends StatelessWidget {
  final double size;

  const JungleMascot({super.key, this.size = 120});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _ThinkingHeadPainter()),
    );
  }
}

/// Public entry point so the launcher icon renderer (test shim) paints
/// the identical artwork.
void paintJungleMascot(Canvas canvas, Size size) =>
    _ThinkingHeadPainter().paint(canvas, size);

class _ThinkingHeadPainter extends CustomPainter {
  static const _skin = Color(0xFFF2E1CE);
  static const _skinShade = Color(0xFFDDBFA4);
  static const _hair = Color(0xFF1C2426);
  static const _hairShine = Color(0xFF39464A);
  static const _accent = Color(0xFF8FBF9F);
  static const _ink = Color(0xFF262D2F);
  static const _shirt = Color(0xFF1E2A25);
  static const _bgA = Color(0xFF1A2124);
  static const _bgB = Color(0xFF101517);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 120; // design space: 120x120
    Offset p(double x, double y) => Offset(x * s, y * s);

    // ---- Backdrop: radial-lit dark disc + ring ---------------------------
    final bgCenter = p(60, 60);
    final bgRect = Rect.fromCircle(center: bgCenter, radius: 57 * s);
    canvas.drawCircle(
      bgCenter,
      57 * s,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.35, -0.45),
          colors: [_bgA, _bgB],
        ).createShader(bgRect),
    );
    canvas.drawCircle(
      bgCenter,
      57 * s,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6 * s
        ..color = _accent.withValues(alpha: 0.45),
    );

    // ---- Collar / shoulders ----------------------------------------------
    final shirt = Paint()..color = _shirt;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
            center: p(60, 112), width: 74 * s, height: 34 * s),
        Radius.circular(16 * s),
      ),
      shirt,
    );

    // ---- Neck --------------------------------------------------------------
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
            center: p(56, 92), width: 20 * s, height: 26 * s),
        Radius.circular(7 * s),
      ),
      Paint()..color = _skinShade,
    );

    // ---- Hair mass (behind head) -------------------------------------------
    canvas.drawCircle(p(64, 46), 34 * s, Paint()..color = _hair);

    // ---- Head ----------------------------------------------------------------
    canvas.drawCircle(p(58, 55), 30 * s, Paint()..color = _skin);

    // Jaw toward the hand.
    canvas.drawCircle(p(50, 72), 20 * s, Paint()..color = _skin);

    // Hair crescent over the forehead (smooth bezier sweep) + shine strand.
    final hairPath = Path()
      ..moveTo(p(29, 52).dx, p(29, 52).dy)
      ..quadraticBezierTo(
          p(31, 25).dx, p(31, 25).dy, p(60, 26).dx, p(60, 26).dy)
      ..quadraticBezierTo(
          p(86, 28).dx, p(86, 28).dy, p(87, 50).dx, p(87, 50).dy)
      ..quadraticBezierTo(
          p(78, 38).dx, p(78, 38).dy, p(58, 40).dx, p(58, 40).dy)
      ..quadraticBezierTo(
          p(40, 41).dx, p(40, 41).dy, p(29, 52).dx, p(29, 52).dy)
      ..close();
    canvas.drawPath(hairPath, Paint()..color = _hair);
    // Hair shine strand.
    final shine = Path()
      ..moveTo(p(38, 33).dx, p(38, 33).dy)
      ..quadraticBezierTo(
          p(52, 28).dx, p(52, 28).dy, p(72, 32).dx, p(72, 32).dy);
    canvas.drawPath(
      shine,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6 * s
        ..color = _hairShine
        ..strokeCap = StrokeCap.round,
    );

    // ---- Ear -------------------------------------------------------------------
    canvas.drawCircle(p(76, 60), 5.5 * s, Paint()..color = _skin);
    canvas.drawCircle(p(76, 60), 2.4 * s, Paint()..color = _skinShade);

    // ---- Face: closed thinking eye, brow, nose ---------------------------------
    final inkStroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.3 * s
      ..strokeCap = StrokeCap.round
      ..color = _ink;
    // Brow.
    canvas.drawLine(p(40, 51), p(53, 52.5), inkStroke);
    // Closed eye (gentle downward arc).
    final eye = Path()
      ..moveTo(p(40, 58).dx, p(40, 58).dy)
      ..quadraticBezierTo(
          p(46.5, 61).dx, p(46.5, 61).dy, p(53, 58).dx, p(53, 58).dy);
    canvas.drawPath(eye, inkStroke);
    // Nose hint.
    canvas.drawLine(p(33.5, 62), p(31.5, 68), inkStroke..strokeWidth = 1.8 * s);
    // Mouth hint.
    canvas.drawLine(
        p(38, 74.5), p(45, 75), Paint()..color = _skinShade..strokeWidth = 1.6 * s);

    // ---- Hand under the chin -----------------------------------------------------
    canvas.drawCircle(p(46, 82), 10.5 * s, Paint()..color = _skin);
    canvas.drawCircle(p(57, 84), 8.8 * s, Paint()..color = _skin);
    final finger = Paint()
      ..color = _skinShade
      ..strokeWidth = 1.4 * s
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(p(39, 78.5), p(53, 76.5), finger);
    canvas.drawLine(p(38, 83), p(52, 81), finger);
    canvas.drawLine(p(38.5, 87.5), p(51, 85.5), finger);

    // Arm going down-left, behind the collar edge.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
            center: p(34, 104), width: 17 * s, height: 30 * s),
        Radius.circular(8 * s),
      ),
      Paint()..color = _skin,
    );

    // ---- Thought bubbles -----------------------------------------------------------
    final bubble = Paint()..color = _accent;
    canvas.drawCircle(p(88, 82), 2.6 * s, bubble);
    canvas.drawCircle(p(95, 70), 3.8 * s, bubble);
    canvas.drawCircle(p(102, 54), 5.6 * s, bubble);
    canvas.drawCircle(p(102, 54), 2.1 * s, Paint()..color = _bgB);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
