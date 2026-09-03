import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/safe_errors.dart';
import '../../core/theme.dart';
import '../../services/auth_service.dart';
import '../../services/feedback_service.dart';

/// Master-key reset (PRD §11): the recovery credential is the ONLY reset
/// path. Verifies Animal ID + credential, sets a new login password, and
/// enters the app with a fresh session.
class ResetPasswordScreen extends StatefulWidget {
  const ResetPasswordScreen({super.key});

  @override
  State<ResetPasswordScreen> createState() => _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends State<ResetPasswordScreen> {
  final _id = TextEditingController();
  final _credential = TextEditingController();
  final _newPassword = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _id.dispose();
    _credential.dispose();
    _newPassword.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _reset() async {
    if (_busy) return;
    if (_newPassword.text.length < 8) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('New password must be at least 8 characters.'),
        ),
      );
      return;
    }
    if (_newPassword.text != _confirm.text) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('The two passwords do not match.')),
      );
      return;
    }

    setState(() => _busy = true);
    try {
      await AuthService().resetPassword(
        animalId: _id.text,
        credential: _credential.text,
        newPassword: _newPassword.text,
      );
      if (!mounted) return;
      context.go('/home');
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            e.toString().contains('INVALID_PASSWORD')
                ? 'New password must be 8–72 characters.'
                : SafeErrors.invalidCredentials,
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('RESET PASSWORD')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
          children: [
            Text(
              'Forgot your password?\n'
              'Your recovery credential is the master key. '
              'Use it here to set a new password.',
              style: JCTypography.secondary.copyWith(height: 1.5),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _id,
              textCapitalization: TextCapitalization.characters,
              enableSuggestions: false,
              style: JCTypography.animalId.copyWith(letterSpacing: 2),
              decoration: const InputDecoration(
                labelText: 'Animal ID',
                hintText: 'WOLF-427',
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _credential,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Recovery credential',
                hintText: 'XXXX-XXXX-XXXX-XXXX-XXXX',
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _newPassword,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'New password (min 8 characters)',
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _confirm,
              obscureText: true,
              onSubmitted: (_) => _reset(),
              decoration: const InputDecoration(
                labelText: 'Repeat new password',
              ),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _busy ? null : FeedbackService.click(_reset),
              child: Text(_busy ? 'RESETTING…' : 'RESET & ENTER'),
            ),
          ],
        ),
      ),
    );
  }
}
