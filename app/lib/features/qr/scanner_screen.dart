import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/theme.dart';
import 'my_qr_screen.dart';

/// Camera scanner: detects an JungleChat QR and returns the Animal ID.
class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key});

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> {
  bool _handled = false;
  MobileScannerController? _controller;

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return; // one code per session; debounce spam
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value == null) continue;
      final animalId = parseAnimalPayload(value);
      if (animalId != null) {
        _handled = true;
        _controller?.stop();
        if (mounted) Navigator.pop(context, animalId);
        return;
      }
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('SCAN QR'),
        backgroundColor: Colors.black,
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller ??= MobileScannerController(),
            onDetect: _onDetect,
          ),
          // Aim frame.
          IgnoreChild(
            child: Center(
              child: Container(
                width: 240,
                height: 240,
                decoration: BoxDecoration(
                  border: Border.all(color: JCColors.accent, width: 3),
                  borderRadius: BorderRadius.circular(24),
                ),
              ),
            ),
          ),
          Positioned(
            bottom: 40,
            left: 0,
            right: 0,
            child: Text(
              'Point at an JungleChat QR code',
              textAlign: TextAlign.center,
              style: JCTypography.secondary.copyWith(color: Colors.white70),
            ),
          ),
        ],
      ),
    );
  }
}

/// Transparent passthrough so the frame overlay never blocks the camera
/// gestures.
class IgnoreChild extends StatelessWidget {
  final Widget child;
  const IgnoreChild({super.key, required this.child});

  @override
  Widget build(BuildContext context) => IgnorePointer(child: child);
}
