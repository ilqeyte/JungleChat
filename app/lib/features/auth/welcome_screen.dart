import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/theme.dart';
import '../../services/auth_service.dart';
import '../../services/feedback_service.dart';
import '../onboarding/welcome_dialog.dart';

/// PRD §4: "JungleChat — No name. No face. Just you."
/// Real authorization lives entirely on the backend.
final authServiceProvider = Provider<AuthService>((_) => AuthService());

class WelcomeScreen extends ConsumerStatefulWidget {
  const WelcomeScreen({super.key});

  @override
  ConsumerState<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends ConsumerState<WelcomeScreen> {
  @override
  void initState() {
    super.initState();
    _showWelcomeDialogIfNeeded();
  }

  Future<void> _showWelcomeDialogIfNeeded() async {
    final prefs = await SharedPreferences.getInstance();
    final shown = prefs.getBool('welcome_dialog_shown') ?? false;
    if (!shown && mounted) {
      await WelcomeDialog.showWelcomeDialog(context);
      await prefs.setBool('welcome_dialog_shown', true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        // Scroll-safe on every screen size: short devices scroll instead of
        // overflowing; tall devices center via the flexible spacers.
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: IntrinsicHeight(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: Column(
                    children: [
                      const Text(
                        'JungleChat',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 30,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.5,
                          color: JCColors.accent,
                        ),
                      ),
                      const SizedBox(height: 14),
                      const Text(
                        'No name.\nNo face.\nJust you.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 17,
                          height: 1.6,
                          color: JCColors.textSecondary,
                        ),
                      ),
                      const Spacer(flex: 3),
                      FilledButton(
                        onPressed: FeedbackService.click(
                          () => context.push('/choose-animal'),
                        ),
                        child: const Text('CREATE ACCOUNT'),
                      ),
                      const SizedBox(height: 14),
                      ElevatedButton(
                        onPressed: FeedbackService.click(
                          () => context.push('/login'),
                        ),
                        child: const Text('LOGIN'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
