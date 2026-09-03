import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../core/safe_errors.dart';
import '../../core/theme.dart';
import '../../services/auth_service.dart';
import '../../services/feedback_service.dart';

/// PRD §9 — the credential is displayed EXACTLY ONCE. It is never persisted,
/// never logged, never sent anywhere. A confirmation checkbox is mandatory
/// before the account is considered created.
class RecoveryCredentialScreen extends StatefulWidget {
  final String animalId;
  final String credential;

  const RecoveryCredentialScreen({
    super.key,
    required this.animalId,
    required this.credential,
  });

  @override
  State<RecoveryCredentialScreen> createState() =>
      _RecoveryCredentialScreenState();
}

class _RecoveryCredentialScreenState extends State<RecoveryCredentialScreen> {
  bool _saved = false;
  bool _signingIn = false;

  /// Account creation does NOT establish a session by design (the credential
  /// is shown once, then used exactly like a login). Entering the app signs
  /// in with Animal ID + credential through the trusted login function.
  Future<void> _enter() async {
    if (_signingIn) return;
    setState(() => _signingIn = true);
    try {
      await AuthService().login(widget.animalId, widget.credential);
      if (!mounted) return;
      context.go('/home');
    } catch (e) {
      if (!mounted) return;
      setState(() => _signingIn = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(SafeErrors.message(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false, // no accidental back navigation past this screen
      child: Scaffold(
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
            children: [
              const SizedBox(height: 12),
              Text(
                'SAVE YOUR RECOVERY CREDENTIAL',
                textAlign: TextAlign.center,
                style: JCTypography.title,
              ),
              const SizedBox(height: 16),
              Text(
                'This is required to access your anonymous account again.\n'
                'Keep it somewhere safe.\n\n'
                'JungleChat cannot safely identify you in the real world '
                'if you lose it.',
                textAlign: TextAlign.center,
                style: JCTypography.secondary.copyWith(height: 1.6),
              ),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 18,
                ),
                decoration: BoxDecoration(
                  color: JCColors.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: JCColors.accentDim, width: 1.5),
                ),
                child: Column(
                  children: [
                    Text(
                      widget.animalId,
                      style: JCTypography.animalId.copyWith(
                        fontSize: 20,
                        letterSpacing: 3,
                      ),
                    ),
                    const SizedBox(height: 12),
                    SelectableText(
                      widget.credential,
                      style: JCTypography.animalId.copyWith(
                        fontSize: 18,
                        letterSpacing: 2,
                        color: JCColors.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              TextButton.icon(
                onPressed: FeedbackService.click(() {
                  Clipboard.setData(ClipboardData(text: widget.credential));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Copied. Paste it somewhere safe.'),
                    ),
                  );
                }),
                icon: const Icon(Icons.copy_rounded, size: 18),
                label: const Text('Copy'),
              ),
              const SizedBox(height: 16),
              CheckboxListTile(
                value: _saved,
                activeColor: JCColors.accent,
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                title: const Text('I saved my recovery credential'),
                onChanged: (v) {
                  FeedbackService.tap();
                  setState(() => _saved = v ?? false);
                },
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: (_saved && !_signingIn)
                    ? FeedbackService.click(_enter)
                    : null,
                child: Text(_signingIn ? 'ENTERING…' : 'ENTER JungleChat'),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}
