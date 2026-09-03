import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../features/auth/choose_animal_screen.dart';
import '../features/auth/login_screen.dart';
import '../features/auth/recovery_credential_screen.dart';
import '../features/auth/reset_password_screen.dart';
import '../features/auth/welcome_screen.dart';
import '../features/chats/private_chat_screen.dart';
import '../features/discovery/meet_animals_screen.dart';
import '../features/discovery/random_talk_screen.dart';
import '../features/discovery/search_animal_screen.dart';
import '../features/groups/create_group_screen.dart';
import '../features/groups/group_chat_screen.dart';
import '../features/groups/group_info_screen.dart';
import '../features/groups/add_group_members_screen.dart';
import '../models/app_update.dart';
import '../features/home/home_shell.dart';
import '../features/notifications/notifications_screen.dart';
import '../features/profile/profile_screen.dart';
import '../features/qr/found_animal_screen.dart';
import '../features/qr/my_qr_screen.dart';
import '../features/qr/scanner_screen.dart';
import '../features/update/update_screen_page.dart';

/// Global navigator key so code without a BuildContext (update flow,
/// notification tap handlers) can show snackbars and navigate.
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

GoRouter? _appRouter;

/// The app's router. Kept as a global handle because notification taps and
/// the update gate trigger navigation from outside the widget tree.
GoRouter get appRouter => _appRouter!;

final routerProvider = Provider<GoRouter>((ref) {
  return _appRouter ??= GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: '/',
    redirect: (context, state) {
      final session = Supabase.instance.client.auth.currentSession;
      final loggedIn = session != null;
      final loggingIn =
          state.matchedLocation == '/login' ||
          state.matchedLocation == '/reset-password' ||
          state.matchedLocation == '/welcome' ||
          state.matchedLocation == '/choose-animal' ||
          state.matchedLocation == '/recovery-credential' ||
          state.matchedLocation == '/update';
      if (!loggedIn && !loggingIn) return '/welcome';
      if (loggedIn && state.matchedLocation == '/') return '/home';
      return null;
    },
    routes: [
      GoRoute(path: '/', redirect: (context, state) => '/welcome'),
      GoRoute(path: '/welcome', builder: (_, _) => const WelcomeScreen()),
      GoRoute(
        path: '/choose-animal',
        builder: (_, _) => const ChooseAnimalScreen(),
      ),
      GoRoute(
        path: '/recovery-credential',
        builder: (_, state) {
          final args = state.extra as Map<String, String>? ?? const {};
          return RecoveryCredentialScreen(
            animalId: args['animalId'] ?? '',
            credential: args['credential'] ?? '',
          );
        },
      ),
      GoRoute(path: '/login', builder: (_, _) => const LoginScreen()),
      GoRoute(
        path: '/reset-password',
        builder: (_, _) => const ResetPasswordScreen(),
      ),
      GoRoute(path: '/home', builder: (_, _) => const HomeShell()),
      GoRoute(path: '/meet', builder: (_, _) => const MeetAnimalsScreen()),
      GoRoute(path: '/random', builder: (_, _) => const RandomTalkScreen()),
      GoRoute(path: '/search', builder: (_, _) => const SearchAnimalScreen()),
      GoRoute(
        path: '/notifications',
        builder: (_, _) => const NotificationsScreen(),
      ),
      GoRoute(
        path: '/animal/:id',
        builder: (_, state) =>
            FoundAnimalScreen(animalId: state.pathParameters['id']!),
      ),
      // Public profile of one animal (bio, presence). Prefill passed via
      // extra so the header renders instantly.
      GoRoute(
        path: '/profile/:id',
        builder: (_, state) {
          final extra = state.extra as Map<String, dynamic>?;
          return ProfileScreen(
            userId: state.pathParameters['id']!,
            displayId: extra?['displayId'] as String?,
            animal: extra?['animal'] as String?,
          );
        },
      ),
      GoRoute(path: '/my-qr', builder: (_, _) => const MyQrScreen()),
      GoRoute(path: '/scan', builder: (_, _) => const ScannerScreen()),
      GoRoute(
        path: '/chat/:id',
        builder: (_, state) =>
            PrivateChatScreen(conversationId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/create-group',
        builder: (_, _) => const CreateGroupScreen(),
      ),
      GoRoute(
        path: '/group/:id',
        builder: (_, state) => GroupChatScreen(
          groupId: state.pathParameters['id']!,
          groupName: (state.extra as Map<String, dynamic>?)?['name'] as String?,
        ),
      ),
      GoRoute(
        path: '/group-info/:id',
        builder: (_, state) => GroupInfoScreen(
          groupId: state.pathParameters['id']!,
          groupName: (state.extra as Map<String, dynamic>?)?['name'] as String?,
        ),
      ),
      GoRoute(
        path: '/add-group-members/:id',
        builder: (_, state) => AddGroupMembersScreen(
          groupId: state.pathParameters['id']!,
          groupName: (state.extra as Map<String, dynamic>?)?['name'] as String?,
        ),
      ),
      // In-app update screen. Reached from notification taps, the settings
      // "Check for updates" tile, and the gate's optional-release prompt.
      // Allowed while logged out: an update matters before login too.
      GoRoute(
        path: '/update',
        builder: (_, state) => UpdateScreenPage(
          update: state.extra is AppUpdate ? state.extra as AppUpdate : null,
        ),
      ),
    ],
    errorBuilder: (_, _) =>
        const Scaffold(body: Center(child: Text('Page not found'))),
  );
});
