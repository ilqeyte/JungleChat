import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import 'passcode_service.dart';

/// Full-screen passcode prompt shown by [LockGate] on cold start and resume.
///
/// Biometric unlock is offered as a convenience alias when available; the PIN
/// remains the sole root credential. After 5 wrong attempts the input is locked
/// out with an exponential backoff; after 10 the caller's [onWipe] fires.
class LockScreen extends ConsumerStatefulWidget {
  final VoidCallback onSuccess;
  final VoidCallback? onWipe;
  const LockScreen({required this.onSuccess, this.onWipe, super.key});

  @override
  ConsumerState<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends ConsumerState<LockScreen> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  bool _busy = false;
  bool _canBiometric = false;
  String? _error;
  int? _backoffSeconds;

  @override
  void initState() {
    super.initState();
    _loadBiometric();
  }

  Future<void> _loadBiometric() async {
    final ok = await PasscodeService.instance.canAuthenticateBiometric;
    if (mounted) {
      setState(() => _canBiometric = ok);
      if (ok) _focus.requestFocus();
    }
  }

  Future<void> _submit() async {
    final pin = _controller.text;
    if (!RegExp(r'^\d{6}$').hasMatch(pin)) {
      setState(() => _error = 'Enter your 6-digit passcode');
      return;
    }
    setState(() => _busy = true);
    final ok = await PasscodeService.instance.verifyPin(pin);
    if (!mounted) return;
    if (ok) {
      await PasscodeService.instance.resetFailures();
      widget.onSuccess();
      return;
    }
    final fails = await PasscodeService.instance.recordFailureAndGet();
    if (fails >= 10) {
      widget.onWipe?.call();
      return;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _controller.clear();
      _error = fails >= 5
          ? 'Too many attempts — try again shortly'
          : 'Incorrect passcode';
    });
    if (fails >= 5) {
      final wait = [10, 20, 40, 80, 160][(fails - 5).clamp(0, 4)];
      setState(() => _backoffSeconds = wait);
      Future.delayed(Duration(seconds: wait), () {
        if (mounted) {
          setState(() => _backoffSeconds = null);
          _focus.requestFocus();
        }
      });
    } else {
      _focus.requestFocus();
    }
  }

  Future<void> _biometric() async {
    final ok = await PasscodeService.instance.authenticateBiometric();
    if (ok && mounted) widget.onSuccess();
  }

  @override
  Widget build(BuildContext context) {
    final locked = _backoffSeconds != null;
    return Scaffold(
      backgroundColor: JCColors.surface,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline_rounded, size: 48, color: JCColors.accent),
              const SizedBox(height: 16),
              Text('Enter passcode', style: JCTypography.title),
              const SizedBox(height: 24),
              TextField(
                controller: _controller,
                focusNode: _focus,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                enableInteractiveSelection: false,
                keyboardType: TextInputType.number,
                maxLength: 6,
                textAlign: TextAlign.center,
                style: JCTypography.body.copyWith(letterSpacing: 8),
                onChanged: (_) => setState(() => _error = null),
                onSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  hintText: '••••••',
                  errorText: _error,
                  counterText: '',
                ),
              ),
              const SizedBox(height: 16),
              if (locked)
                Text(
                  'Try again in $_backoffSeconds s',
                  style: JCTypography.secondary,
                ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _busy || locked ? null : _submit,
                child: const Text('UNLOCK'),
              ),
              if (_canBiometric)
                TextButton(
                  onPressed: _busy || locked ? null : _biometric,
                  child: const Text('Use biometrics'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
