import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'lock_screen.dart';
import 'passcode_service.dart';

/// Wraps the app and forces a passcode/biometric gate whenever required:
///   * on cold start, if a PIN is set;
/// * on every resume from the background, if a PIN is set.
///
/// The underlying [child] (the real MaterialApp) is only mounted while
/// unlocked, so its navigator/state is cleanly rebuilt after unlocking. Riverpod
/// state at the [ProviderScope] level survives, so auth/session state is kept.
class LockGate extends ConsumerStatefulWidget {
  final Widget child;
  final Future<void> Function()? onWipe;
  const LockGate({required this.child, this.onWipe, super.key});

  @override
  ConsumerState<LockGate> createState() => _LockGateState();
}

class _LockGateState extends ConsumerState<LockGate> with WidgetsBindingObserver {
  bool _locked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _evaluate();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _evaluate() async {
    if (await PasscodeService.instance.isPinSet() && mounted) {
      setState(() => _locked = true);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _evaluate();
  }

  @override
  Widget build(BuildContext context) {
    if (_locked) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true),
        home: LockScreen(
          onSuccess: () {
            if (mounted) setState(() => _locked = false);
          },
          onWipe: () async {
            await PasscodeService.instance.clear();
            await widget.onWipe?.call();
            if (mounted) setState(() => _locked = false);
          },
        ),
      );
    }
    return widget.child;
  }
}
