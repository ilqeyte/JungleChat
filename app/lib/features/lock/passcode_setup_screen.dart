import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import 'passcode_service.dart';

/// One-time (or change) passcode setup. Requires a 6-digit PIN entered twice.
/// On success the caller's [onDone] fires.
class PasscodeSetupScreen extends ConsumerStatefulWidget {
  final VoidCallback onDone;
  const PasscodeSetupScreen({required this.onDone, super.key});

  @override
  ConsumerState<PasscodeSetupScreen> createState() => _PasscodeSetupScreenState();
}

class _PasscodeSetupScreenState extends ConsumerState<PasscodeSetupScreen> {
  final _first = TextEditingController();
  final _second = TextEditingController();
  String? _error;
  bool _busy = false;

  Future<void> _save() async {
    final p1 = _first.text;
    final p2 = _second.text;
    if (!RegExp(r'^\d{6}$').hasMatch(p1)) {
      setState(() => _error = 'Passcode must be exactly 6 digits');
      return;
    }
    if (p1 != p2) {
      setState(() => _error = 'Passcodes do not match');
      return;
    }
    setState(() => _busy = true);
    await PasscodeService.instance.setPin(p1);
    if (!mounted) return;
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: JCColors.surface,
      appBar: AppBar(title: const Text('Set passcode')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Choose a 6-digit passcode to lock the app. Biometric unlock can '
              'be used instead once this is set.',
              style: JCTypography.secondary,
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _first,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              enableInteractiveSelection: false,
              keyboardType: TextInputType.number,
              maxLength: 6,
              textAlign: TextAlign.center,
              style: JCTypography.body.copyWith(letterSpacing: 8),
              decoration: InputDecoration(
                hintText: '••••••',
                labelText: 'Passcode',
                errorText: _error,
                counterText: '',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _second,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              enableInteractiveSelection: false,
              keyboardType: TextInputType.number,
              maxLength: 6,
              textAlign: TextAlign.center,
              style: JCTypography.body.copyWith(letterSpacing: 8),
              onSubmitted: (_) => _save(),
              decoration: InputDecoration(
                hintText: '••••••',
                labelText: 'Confirm passcode',
                counterText: '',
              ),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _busy ? null : _save,
              child: const Text('SAVE'),
            ),
          ],
        ),
      ),
    );
  }
}
