import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/animal_glyph.dart';
import '../../core/theme.dart';
import '../../services/auth_service.dart';

/// The payload every QR encodes. Custom scheme so native camera apps open
/// JungleChat directly (intent filter in the manifest).
String qrPayloadFor(String displayAnimalId) =>
    'junglechat://animal/$displayAnimalId';

/// Extracts the Animal ID from a scanned payload. Accepts both the custom
/// scheme and a bare Animal ID. Returns null for foreign codes.
String? parseAnimalPayload(String raw) {
  final s = raw.trim();
  final match = RegExp(r'^junglechat://animal/([A-Za-z]+\-\d{1,6})$')
      .firstMatch(s);
  if (match != null) return match.group(1)!.toUpperCase();
  final bare = s.toUpperCase();
  if (RegExp(r'^[A-Z]{3,20}-\d{1,6}$').hasMatch(bare)) return bare;
  return null;
}

/// My QR code screen — another animal scans this and lands on my card.
class MyQrScreen extends StatefulWidget {
  const MyQrScreen({super.key});

  @override
  State<MyQrScreen> createState() => _MyQrScreenState();
}

class _MyQrScreenState extends State<MyQrScreen> {
  String _animal = '';
  String _displayAnimalId = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final p = await AuthService().fetchMyProfile();
      if (!mounted) return;
      setState(() {
        _animal = p?.animal ?? '';
        _displayAnimalId = p?.displayAnimalId ?? '';
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('MY QR CODE')),
      body: SafeArea(
        child: _loading
            ? const Center(
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: JCColors.accent,
                ),
              )
            : ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      AnimalGlyph(animal: _animal, size: 26),
                      const SizedBox(width: 10),
                      Text(
                        _displayAnimalId,
                        style: JCTypography.animalId.copyWith(fontSize: 18),
                      ),
                    ],
                  ),
                  const SizedBox(height: 22),
                  Center(
                    child: Container(
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(color: JCColors.accentDim, width: 2),
                      ),
                      child: QrImageView(
                        data: qrPayloadFor(_displayAnimalId),
                        size: 240,
                        backgroundColor: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Center(
                    child: Text(
                      _displayAnimalId,
                      style: JCTypography.animalId.copyWith(fontSize: 22),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Another animal scans this with the SCAN button —\n'
                    'they find you instantly and can request to talk.\n'
                    'Scanning it with the normal camera app opens\n'
                    'JungleChat too. Screenshot and share it anywhere.',
                    textAlign: TextAlign.center,
                    style: JCTypography.secondary.copyWith(height: 1.5),
                  ),
                ],
              ),
      ),
    );
  }
}
