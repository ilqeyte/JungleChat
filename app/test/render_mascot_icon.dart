// Renders the JungleMascot vector painter to a 1024px PNG launcher icon.
// Run inside the app package: flutter test test/render_mascot_icon.dart
//
// This reuses the EXACT painter shown in the app, so the launcher icon and
// the in-app mascot are always identical.
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:junglechat/core/jungle_mascot.dart';

void main() {
  test('render mascot icon png', () async {
    const size = 1024;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);

    paintMascotForTest(canvas, Size(size.toDouble(), size.toDouble()));

    final picture = recorder.endRecording();
    final image = await picture.toImage(size, size);
    final bytes =
        await image.toByteData(format: ui.ImageByteFormat.png);
    Directory('assets/icon').createSync(recursive: true);
    File('assets/icon/junglechat_icon.png')
        .writeAsBytesSync(bytes!.buffer.asUint8List());
    // ignore: avoid_print
  print('icon rendered: assets/icon/junglechat_icon.png');
  });
}

/// Public shim: re-exported painter logic.
void paintMascotForTest(Canvas canvas, Size size) {
  paintJungleMascot(canvas, size);
}
