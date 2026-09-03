// Generates the JungleChat launcher icon (thinking-head mascot).
// Run: dart run tool/generate_icon.dart
// Output: assets/icon/junglechat_icon.png (1024x1024)
import 'dart:io';
import 'package:image/image.dart' as img;

final bg = img.ColorUint8.rgb(0x13, 0x18, 0x1A);
final ring = img.ColorUint8.rgb(0x41, 0x59, 0x4C);
final skin = img.ColorUint8.rgb(0xEF, 0xDC, 0xC8);
final skinShade = img.ColorUint8.rgb(0xD9, 0xBF, 0xA6);
final hair = img.ColorUint8.rgb(0x23, 0x2B, 0x2E);
final accent = img.ColorUint8.rgb(0x8F, 0xBF, 0x9F);
final dark = img.ColorUint8.rgb(0x13, 0x18, 0x1A);
final ink = img.ColorUint8.rgb(0x2A, 0x2F, 0x31);

void circle(img.Image im, int cx, int cy, int r, dynamic c) =>
    img.fillCircle(im, x: cx, y: cy, radius: r, color: c);

void line(img.Image im, int x1, int y1, int x2, int y2, dynamic c,
    [int t = 5]) {
  final distSq = (x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1);
  final steps = distSq <= 0 ? 1 : 2 * distSq;
  for (var i = 0; i <= steps; i++) {
    final x = x1 + ((x2 - x1) * i / steps).round();
    final y = y1 + ((y2 - y1) * i / steps).round();
    circle(im, x, y, t, c);
  }
}

void main() async {
  const size = 1024;
  final im = img.Image(width: size, height: size);

  // Dark backdrop disc with ring.
  img.fill(im, color: bg);
  circle(im, 512, 512, 480, ring);
  circle(im, 512, 512, 468, bg);

  // ---- Collar / shoulders (drawn early, head overlaps it) ----------------
  final collar = img.ColorUint8.rgb(0x1E, 0x2A, 0x25);
  img.fillRect(im, x1: 330, y1: 730, x2: 660, y2: 870, color: collar);
  circle(im, 390, 800, 70, collar);
  circle(im, 600, 800, 70, collar);

  // ---- Neck ---------------------------------------------------------------
  img.fillRect(im, x1: 430, y1: 640, x2: 515, y2: 745, color: skinShade);

  // ---- Hair mass (drawn before the head so the head carves the face) -----
  circle(im, 530, 415, 165, hair);

  // ---- Head -----------------------------------------------------------------
  circle(im, 490, 480, 155, skin);

  // Jaw rounding toward the hand.
  circle(im, 440, 585, 95, skin);

  // Nose bump on the profile edge.
  circle(im, 335, 500, 25, skin);

  // ---- Ear ----------------------------------------------------------------
  circle(im, 615, 505, 34, skin);
  circle(im, 615, 505, 15, skinShade);

  // ---- Closed thinking eye + brow ----------------------------------------
  line(im, 408, 462, 468, 462, ink, 7);
  line(im, 402, 434, 472, 441, ink, 6);

  // ---- Mouth hint ----------------------------------------------------------
  line(im, 352, 548, 402, 551, skinShade, 4);

  // ---- Arm (behind the collar) ----------------------------------------------
  img.fillRect(im, x1: 300, y1: 690, x2: 400, y2: 830, color: skin);

  // ---- Hand under the chin (fist) + finger lines ---------------------------
  circle(im, 405, 660, 60, skin);
  circle(im, 482, 672, 50, skin);
  line(im, 352, 638, 462, 624, skinShade, 4);
  line(im, 346, 676, 458, 662, skinShade, 4);

  // ---- Thought bubbles rising upper-right -----------------------------------
  circle(im, 810, 760, 24, accent);
  circle(im, 880, 640, 34, accent);
  circle(im, 930, 510, 45, accent);
  circle(im, 930, 510, 17, dark);
  Directory('assets/icon').createSync(recursive: true);
  File('assets/icon/junglechat_icon.png')
      .writeAsBytesSync(img.encodePng(im));
  print('icon written: assets/icon/junglechat_icon.png');
}