import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/router.dart';
import 'core/secure_session.dart';
import 'core/theme.dart';
import 'core/config.dart';
import 'features/admin/kick_out_listener.dart';
import 'features/update/update_gate.dart';
import 'services/notification_service.dart';
import 'features/lock/lock_gate.dart';

@pragma('vm:entry-point')
Future<void> _firebaseBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  await NotificationService.backgroundHandler(message);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Firebase and Supabase are independent — initializing them concurrently
  // shaves a noticeable chunk off cold start on low-end devices.
  final firebaseReady = Firebase.initializeApp()
      .then((_) {
        FirebaseMessaging.onBackgroundMessage(_firebaseBackgroundHandler);

        // Cold start FROM a notification tap: FCM hands back the message that
        // launched the app. Update taps route to the update screen; the flow
        // itself waits for the update gate's first check before navigating.
        FirebaseMessaging.instance.getInitialMessage().then((message) {
          if (message != null) {
            NotificationService.handleRemoteMessage(message);
          }
        });
      })
      .catchError((_) {
        // No Firebase (offline first run, Play services missing): the app
        // still works, only push is unavailable.
      });

  await Supabase.initialize(
    url: AppConfig.supabaseUrl,
    publishableKey: AppConfig.supabasePublishableKey,
    authOptions: FlutterAuthClientOptions(localStorage: SecureSessionStorage()),
  );

  // Don't block startup on Firebase finishing — but don't leave its future
  // dangling either.
  unawaited(firebaseReady);

  runApp(
    ProviderScope(
      child: UpdateGate(
        child: KickOutListener(
          child: LockGate(
            // Brute-force threshold reached: clear the local PIN and sign the
            // user out so no local data can be decrypted or reused.
            onWipe: () async {
              try {
                await Supabase.instance.client.auth.signOut();
              } catch (_) {}
            },
            child: const JungleChatApp(),
          ),
        ),
      ),
    ),
  );
}

/// Phase 7 (item #9): drops the platform overscroll glow so nothing grey
/// flashes against the pure-black background.
class NoGlowScrollBehavior extends ScrollBehavior {
  const NoGlowScrollBehavior();

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) =>
      child;
}

class JungleChatApp extends ConsumerWidget {
  const JungleChatApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: 'JungleChat',
      debugShowCheckedModeBanner: false,
      theme: buildJungleTheme(),
      // Phase 7 (item #9): the default Android overscroll glow is grey and
      // looks wrong against a true-black background. Remove it app-wide.
      scrollBehavior: const NoGlowScrollBehavior(),
      routerConfig: ref.watch(routerProvider),
      builder: (context, child) {
        final mq = MediaQuery.of(context);
        final scale = mq.textScaler.scale(14) / 14;
        final clamped = TextScaler.linear(scale.clamp(0.85, 1.25));
        return MediaQuery(
          data: mq.copyWith(textScaler: clamped),
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
  }
}
