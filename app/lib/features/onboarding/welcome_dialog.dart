import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/theme.dart';
import '../../services/feedback_service.dart';

/// Shows a welcome dialog for first-time users
class WelcomeDialog extends ConsumerStatefulWidget {
  const WelcomeDialog({super.key});

  @override
  ConsumerState<WelcomeDialog> createState() => _WelcomeDialogState();

  static Future<void> showWelcomeDialog(BuildContext context) async {
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const WelcomeDialog(),
    );
  }
}

class _WelcomeDialogState extends ConsumerState<WelcomeDialog> {
  int _currentPage = 0;
  final PageController _pageController = PageController();

  static const String _prefsKey = 'welcome_dialog_shown';

  static const List<_WelcomePage> _pages = [
    _WelcomePage(
      title: 'Welcome to JungleChat',
      description: 'An anonymous chat app where you discover and connect with others through animal identities.',
      icon: Icons.pets_rounded,
      color: 0xFF4CAF50,
    ),
    _WelcomePage(
      title: 'Your Animal Identity',
      description: 'You\'ll be assigned a unique animal ID (like WOLF-427). This is your anonymous identity - no real names, no phone numbers.',
      icon: Icons.badge_rounded,
      color: 0xFF2196F3,
    ),
    _WelcomePage(
      title: 'Talk Requests',
      description: 'To start a private chat, send a talk request. The other person must accept before you can message each other.',
      icon: Icons.waving_hand_rounded,
      color: 0xFFFF9800,
    ),
    _WelcomePage(
      title: 'Group Chats',
      description: 'Create group chats with multiple animals. Invite friends, set auto-delete timers, and manage members.',
      icon: Icons.group_rounded,
      color: 0xFF9C27B0,
    ),
    _WelcomePage(
      title: 'Privacy & Safety',
      description: 'Block or report anyone. Use auto-delete timers (24h to 12 months) for disappearing messages. Your data is yours.',
      icon: Icons.shield_rounded,
      color: 0xFFF44336,
    ),
    _WelcomePage(
      title: 'Ready to Start?',
      description: 'Tap "Get Started" to choose your animal and begin your anonymous journey.',
      icon: Icons.rocket_launch_rounded,
      color: 0xFF00BCD4,
      isLast: true,
    ),
  ];

  @override
  void initState() {
    super.initState();
  }

  Future<void> _markAsShown() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsKey, true);
  }

  void _nextPage() {
    if (_currentPage < _pages.length - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else {
      _markAsShown();
      Navigator.pop(context, true);
    }
  }

  void _skip() {
    _markAsShown();
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          _markAsShown();
        }
      },
      child: Dialog(
        backgroundColor: JCColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        insetPadding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400, maxHeight: 600),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Skip button
              Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: TextButton(
                    onPressed: FeedbackService.click(_skip),
                    child: Text(
                      'SKIP',
                      style: JCTypography.secondary.copyWith(
                        color: JCColors.accent,
                      ),
                    ),
                  ),
                ),
              ),
              // Page indicator
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 8,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(_pages.length, (index) {
                    final isActive = index == _currentPage;
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      width: isActive ? 24 : 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: isActive ? JCColors.accent : JCColors.outline,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    );
                  }),
                ),
              ),
              // Pages
              SizedBox(
                height: 350,
                child: PageView.builder(
                  controller: _pageController,
                  itemCount: _pages.length,
                  onPageChanged: (index) =>
                      setState(() => _currentPage = index),
                  itemBuilder: (context, index) {
                    final page = _pages[index];
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 32,
                        vertical: 16,
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            width: 100,
                            height: 100,
                            decoration: BoxDecoration(
                              color: Color(page.color).withAlpha(30),
                              borderRadius: BorderRadius.circular(50),
                            ),
                            child: Icon(
                              page.icon,
                              size: 50,
                              color: Color(page.color),
                            ),
                          ),
                          const SizedBox(height: 24),
                          Text(
                            page.title,
                            style: JCTypography.title.copyWith(fontSize: 22),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            page.description,
                            style: JCTypography.body.copyWith(
                              fontSize: 15,
                              color: JCColors.textSecondary,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              // Next/Get Started button
              Padding(
                padding: const EdgeInsets.all(24),
                child: SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: FilledButton(
                    onPressed: FeedbackService.click(_nextPage),
                    style: FilledButton.styleFrom(
                      backgroundColor: JCColors.accent,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    child: Text(
                      _currentPage == _pages.length - 1
                          ? 'GET STARTED'
                          : 'NEXT',
                      style: JCTypography.body.copyWith(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }
}

class _WelcomePage {
  final String title;
  final String description;
  final IconData icon;
  final int color;
  final bool isLast;

  const _WelcomePage({
    required this.title,
    required this.description,
    required this.icon,
    required this.color,
    this.isLast = false,
  });
}

/// Provider to track if welcome dialog has been shown
final welcomeDialogProvider = FutureProvider<bool>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool('welcome_dialog_shown') ?? false;
});

/// Widget that shows welcome dialog on first launch
class FirstLaunchWrapper extends ConsumerWidget {
  final Widget child;

  const FirstLaunchWrapper({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shownAsync = ref.watch(welcomeDialogProvider);

    return shownAsync.when(
      data: (shown) {
        if (!shown) {
          // Show welcome dialog after a short delay
          WidgetsBinding.instance.addPostFrameCallback((_) {
            showWelcomeDialog(context);
          });
        }
        return child;
      },
      loading: () => child,
      error: (_, _) => child,
    );
  }

  static Future<void> showWelcomeDialog(BuildContext context) async {
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const WelcomeDialog(),
    );
  }
}

/// Call this after user completes onboarding (e.g., after choosing animal)
Future<void> markWelcomeDialogShown() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool('welcome_dialog_shown', true);
}
