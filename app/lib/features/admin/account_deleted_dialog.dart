import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/theme.dart';
import '../../services/feedback_service.dart';

/// Blocking dialog shown when a user's account has been permanently deleted
/// by admin. The account is gone (no undo) — the only path forward is a new
/// account, so the dialog offers no appeal and only "Go to Login".
class AccountDeletedDialog extends StatefulWidget {
  const AccountDeletedDialog({super.key});

  /// Show the dialog and return only when the user navigates away.
  static Future<void> show(BuildContext context) async {
    await showGeneralDialog(
      context: context,
      barrierDismissible: false,
      barrierLabel: 'Account Deleted',
      barrierColor: Colors.black87,
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (ctx, a, b) => const AccountDeletedDialog(),
    );
  }

  @override
  State<AccountDeletedDialog> createState() => _AccountDeletedDialogState();
}

class _AccountDeletedDialogState extends State<AccountDeletedDialog> {
  void _goToLogin() {
    // Sign out then navigate — the router redirect will handle routing
    Supabase.instance.client.auth.signOut().catchError((_) {});
    // Pop all routes — router redirect sends to /welcome
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Dialog(
        backgroundColor: JCColors.surface,
        insetPadding: const EdgeInsets.all(24),
        constraints: const BoxConstraints(minWidth: 280, maxWidth: 380),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Icon
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: JCColors.danger.withAlpha(25),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.block, size: 32, color: JCColors.danger),
                ),
                const SizedBox(height: 16),
                // Title
                Text(
                  'Account Deleted',
                  style: JCTypography.title.copyWith(color: JCColors.danger),
                ),
                const SizedBox(height: 12),
                // Message — terminal: account is gone, only path forward is a
                // new account.
                Text(
                  'Your account has been permanently deleted by the '
                  'administrator. There is no way to recover it — to use the '
                  'app again you must create a new account.',
                  style: JCTypography.secondary,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                // Go to login button
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: FeedbackService.click(_goToLogin),
                    style: FilledButton.styleFrom(
                      backgroundColor: JCColors.danger,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: Text(
                      'Go to Login',
                      style: JCTypography.secondary.copyWith(
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
