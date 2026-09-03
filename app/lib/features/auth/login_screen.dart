import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/safe_errors.dart';
import '../../core/theme.dart';
import '../../services/feedback_service.dart';
import 'welcome_screen.dart';

/// PRD §10: Animal ID + Recovery Credential login. Verification is entirely
/// server-side; failures are uniform and never reveal which factor failed.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _idCtrl = TextEditingController();
  final _credCtrl = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _idCtrl.dispose();
    _credCtrl.dispose(); // holds the recovery credential; drop it promptly.
    super.dispose();
  }

  Future<void> _login() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref.read(authServiceProvider).login(_idCtrl.text, _credCtrl.text);
      if (!mounted) return;
      context.go('/home');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(SafeErrors.invalidCredentials)));
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('LOGIN')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
          children: [
            TextField(
              controller: _idCtrl,
              textCapitalization: TextCapitalization.characters,
              autofillHints: const [],
              enableSuggestions: false,
              style: JCTypography.animalId.copyWith(letterSpacing: 2),
              decoration: const InputDecoration(
                labelText: 'Animal ID',
                hintText: 'WOLF-427',
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _credCtrl,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              onSubmitted: (_) => _login(),
              decoration: const InputDecoration(
                labelText: 'Recovery credential or password',
                hintText: 'XXXX-XXXX-XXXX-XXXX-XXXX  •  or your password',
              ),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _busy ? null : FeedbackService.click(_login),
              child: Text(_busy ? 'LISTENING…' : 'LOGIN'),
            ),
            const SizedBox(height: 14),
            TextButton(
              onPressed: FeedbackService.click(
                () => context.push('/reset-password'),
              ),
              child: const Text(
                'Forgot password? Reset with recovery credential',
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Lost your recovery credential AND password? '
              'The account cannot be recovered — that is what staying anonymous means.',
              textAlign: TextAlign.center,
              style: JCTypography.secondary.copyWith(fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}
