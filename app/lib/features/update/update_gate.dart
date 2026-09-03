import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/theme.dart';
import '../../models/app_update.dart';
import 'required_update_screen.dart';
import 'update_flow.dart';
import 'update_downloader.dart';

/// Decides what the user sees when a release is published.
///
/// * Required and due  -> full-screen blocking update screen
/// * Optional          -> dismissible /update page (once per release)
/// * Nothing           -> the app
///
/// Triggers, so "immediately" actually means immediately:
///   1. A check on startup.
///   2. A Realtime subscription on app_updates, which fires the moment Adam
///      publishes — an app that is already open reacts without a restart.
///   3. A re-check whenever the app comes back to the foreground (Realtime
///      can drop while backgrounded).
///   4. A re-check (and channel rebuild) when the signed-in user changes,
///      because the subscription is RLS-filtered by the caller's role.
///   5. [reload], invoked by notification taps and the settings tile.
class UpdateGate extends StatefulWidget {
  final Widget child;

  const UpdateGate({super.key, required this.child});

  @override
  State<UpdateGate> createState() => _UpdateGateState();

  // ── Static control surface ──────────────────────────────────────────────
  // Lets code without a BuildContext (notification handlers, settings tiles)
  // ask the mounted gate to re-check, and lets them wait for the first check
  // so navigation happens on a live router.

  // Mutable on purpose: a `static final` Completer completes once per
  // process and never again, so a gate that remounts (parent rebuild,
  // hot-restart-adjacent lifecycle, OEM kill+restore) would serve an
  // already-completed future to later awaiters — who would then navigate
  // into a gate that no longer exists. initState resets it when needed.
  static Completer<void> _ready = Completer<void>();

  /// Resolves once the first startup check has finished (success or failure).
  static Future<void> get ready => _ready.future;

  static final ValueNotifier<int> _reloadSignal = ValueNotifier<int>(0);

  /// Asks the mounted gate to re-check for an update right now.
  static void reload() => _reloadSignal.value++;
}

class _UpdateGateState extends State<UpdateGate> with WidgetsBindingObserver {
  final UpdateDownloader _downloader = UpdateDownloader();

  RealtimeChannel? _channel;
  Timer? _deadlineTimer;
  StreamSubscription<AuthState>? _authSub;
  String? _lastAuthUserId;

  AppUpdate? _update;
  bool _checking = true;
  bool _requiredNow = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // WHY: see the _ready declaration. A previously completed Completer
    // would let awaiters through against a gate that is no longer mounted.
    if (UpdateGate._ready.isCompleted) {
      UpdateGate._ready = Completer<void>();
    }
    UpdateGate._reloadSignal.addListener(_check);
    _check();
    _listen();
    _watchAuth();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    UpdateGate._reloadSignal.removeListener(_check);
    _authSub?.cancel();
    _deadlineTimer?.cancel();
    final channel = _channel;
    if (channel != null) {
      Supabase.instance.client.removeChannel(channel);
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back to the app re-checks: the Realtime socket may have been
    // dropped by the OS while backgrounded, and a release published in the
    // meantime should surface immediately, not after a restart. Throttled so
    // rapid app-switching doesn't hammer the RPC.
    if (state == AppLifecycleState.resumed) {
      final now = DateTime.now();
      if (_lastResumeCheck != null &&
          now.difference(_lastResumeCheck!) < _resumeThrottle) {
        return;
      }
      _lastResumeCheck = now;
      _check();
    }
  }

  /// Rebuilds the Realtime channel and re-checks when the signed-in user
  /// actually changes (login/logout). Token refreshes keep the same user and
  /// are ignored.
  void _watchAuth() {
    final auth = Supabase.instance.client.auth;
    _lastAuthUserId = auth.currentSession?.user.id;
    _authSub = auth.onAuthStateChange.listen((s) {
      final userId = s.session?.user.id;
      if (userId == _lastAuthUserId) return;
      _lastAuthUserId = userId;
      _resubscribe();
      _check();
    });
  }

  void _resubscribe() {
    final channel = _channel;
    if (channel != null) {
      Supabase.instance.client.removeChannel(channel);
      _channel = null;
    }
    _listen();
  }

  // Collapse stacked checks (realtime burst + reload signal + resume) and
  // throttle the lifecycle-resume path; user-initiated checks are never
  // throttled.
  bool _checkInFlight = false;
  DateTime? _lastResumeCheck;
  static const _resumeThrottle = Duration(seconds: 30);

  Future<void> _check() async {
    if (_checkInFlight) return;
    _checkInFlight = true;
    // A hung network call must not hold the app on the splash spinner
    // forever — the catch treats a timeout like any other failed check.
    try {
      final update = await _downloader
          .checkForUpdate()
          .timeout(const Duration(seconds: 8));
      if (!mounted) return;

      final requiredNow = update != null && _downloader.isRequiredNow(update);

      setState(() {
        _update = update;
        _requiredNow = requiredNow;
        _checking = false;
      });

      _scheduleDeadlineCheck(update);

      if (update != null && !requiredNow) {
        // Once per release per session; user-initiated checks bypass the
        // dedup. Pushing a route (not a dialog): this context sits ABOVE the
        // app's MaterialApp, so showDialog here would throw.
        UpdateFlow.presentOptional(update);
      }
    } catch (_) {
      // Offline or the RPC is unavailable: never block the app on a check.
      if (mounted) setState(() => _checking = false);
    } finally {
      _checkInFlight = false;
      if (!UpdateGate._ready.isCompleted) UpdateGate._ready.complete();
    }
  }

  /// Re-evaluates when a required release has a future grace deadline, so the
  /// blocking screen appears the moment that deadline passes without needing a
  /// restart.
  void _scheduleDeadlineCheck(AppUpdate? update) {
    _deadlineTimer?.cancel();
    if (update == null || !update.isRequired) return;
    if (_downloader.isRequiredNow(update)) return;

    _deadlineTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (!mounted) return;
      final fresh = _update;
      if (fresh == null) return;
      if (_downloader.isRequiredNow(fresh)) {
        _deadlineTimer?.cancel();
        if (mounted) setState(() => _requiredNow = true);
      }
    });
  }

  void _listen() {
    try {
      final channel = Supabase.instance.client.channel('public:app_updates');
      channel.onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'app_updates',
        callback: (_) => _check(),
      );
      channel.subscribe();
      _channel = channel;
    } catch (_) {
      // Realtime is an enhancement; the startup and resume checks still
      // cover us.
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildJungleTheme(),
        home: const Scaffold(
          body: Center(
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: JCColors.accent,
            ),
          ),
        ),
      );
    }

    if (_requiredNow && _update != null) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildJungleTheme(),
        home: RequiredUpdateScreen(update: _update!),
      );
    }

    return widget.child;
  }
}
