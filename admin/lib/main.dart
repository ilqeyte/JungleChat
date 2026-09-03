import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/config.dart';
import 'core/theme.dart';
import 'core/auth_controller.dart';
import 'features/auth/login_page.dart';
import 'features/auth/mfa_page.dart';
import 'features/shell/admin_shell.dart';
import 'features/shell/unauthorized_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(url: supabaseUrl, publishableKey: supabaseAnonKey);
  runApp(const ProviderScope(child: JungleChatAdminApp()));
}

class JungleChatAdminApp extends StatelessWidget {
  const JungleChatAdminApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'JungleChat Admin',
      debugShowCheckedModeBanner: false,
      theme: jungleAdminTheme(),
      home: const AppRoot(),
    );
  }
}

class AppRoot extends ConsumerStatefulWidget {
  const AppRoot({super.key});

  @override
  ConsumerState<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends ConsumerState<AppRoot> {
  @override
  void initState() {
    super.initState();
    Future.microtask(
        () => ref.read(authControllerProvider.notifier).init());
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    switch (auth.status) {
      case AuthStatus.loading:
        return const _Splash();
      case AuthStatus.unauthenticated:
        return const LoginPage();
      case AuthStatus.needsMfa:
        return const MfaPage();
      case AuthStatus.nonAdmin:
        return const UnauthorizedPage();
      case AuthStatus.authorized:
        return const AdminShell();
    }
  }
}

class _Splash extends StatelessWidget {
  const _Splash();
  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: CircularProgressIndicator(color: JCColors.accent),
      ),
    );
  }
}
