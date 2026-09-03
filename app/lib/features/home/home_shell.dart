import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/theme.dart';
import '../../services/auth_service.dart';
import '../../services/feedback_service.dart';
import '../../services/notification_service.dart';
import '../auth/welcome_screen.dart';
import '../chats/chats_tab.dart';
import '../home/home_tab.dart';
import '../notifications/notifications_screen.dart';
import '../mine/mine_tab.dart';

/// Bottom navigation shell: Chats / Animals / Notifications / Mine.
/// The realtime notifications subscription keeps the unread badge live and
/// warms the socket at startup; in-app alert banners were removed — the
/// Notifications tab is the single surface for them.
final myProfileProvider = FutureProvider.autoDispose<MyProfile?>((ref) async {
  final session = Supabase.instance.client.auth.currentSession;
  if (session == null) return null;
  return ref.read(authServiceProvider).fetchMyProfile();
});

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell>
    with WidgetsBindingObserver {
  int _tab = 0;
  StreamSubscription? _notifSub;
  final Set<String> _seenNotifIds = {};
  MyProfile? _cachedProfile;
  Timer? _heartbeat;
  dynamic _profileListenSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _listenForNotifications();
    // Keep a synchronous cache of the profile so alert banners never get
    // swallowed while the profile future is still loading.
    _profileListenSub = ref.listenManual(myProfileProvider, (_, next) {
      _cachedProfile = next.value;
      // Push haptic preference into the feedback service.
      if (_cachedProfile != null) {
        FeedbackService.hapticsEnabled = _cachedProfile!.hapticsEnabled;
      }
      // Logged in: ask for notification permission + register the push
      // token (once per session; ensureReady is idempotent).
      if (_cachedProfile != null) {
        NotificationService.ensureReady();
        _startHeartbeat();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Backgrounded minutes must not count as presence: the timer stops on
      // pause and the cycle restarts here.
      _startHeartbeat();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _heartbeat?.cancel();
      _heartbeat = null;
      // Leaving / minimizing: messages that arrived while the user was in
      // the app now become real system notifications.
      NotificationService.presentQueuedOnBackground();
    }
  }

  /// Presence heartbeat: pings the server-stamped `heartbeat()` RPC every
  /// minute while the app is foregrounded (and once on launch / resume).
  /// Online = heartbeat within 2 minutes, decided server-side. This does
  /// NOT touch last_active_at (charter rule 10).
  void _startHeartbeat() {
    _heartbeat?.cancel();
    _beat();
    _heartbeat = Timer.periodic(const Duration(minutes: 1), (_) => _beat());
  }

  void _beat() {
    if (_cachedProfile == null) return;
    ref.read(chatServiceProvider).heartbeat().catchError((_) {});
  }

  @override
  void dispose() {
    _heartbeat?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _notifSub?.cancel();
    _profileListenSub?.close();
    super.dispose();
  }

  /// One realtime stream on my notifications (RLS-filtered):
  /// 1. warms the realtime connection at startup (no first-message lag),
  /// 2. keeps the Notifications tab badge live by invalidating the count
  ///    whenever a new unread row lands,
  /// 3. plays the in-app new-message sound/haptic for message kinds —
  ///    the ONLY feedback while the app is open (system notifications are
  ///    deferred until the user leaves; see NotificationService queue).
  void _listenForNotifications() {
    _notifSub = Supabase.instance.client
        .from('notifications')
        .stream(primaryKey: ['id'])
        .order('created_at')
        .limit(20)
        .listen((rows) {
          if (!mounted) return;
          final profile = _cachedProfile;
          if (profile == null) return;
          final appResumed =
              WidgetsBinding.instance.lifecycleState ==
              AppLifecycleState.resumed;
          for (final raw in rows) {
            final n = Map<String, dynamic>.from(raw);
            final id = n['id'] as String;
            if (_seenNotifIds.contains(id)) continue;
            // WHY: cap dedup memory. A long foreground session otherwise
            // accumulates one id per notification forever; on overflow the
            // oldest entry is dropped (dedup window = last ~200 ids).
            if (_seenNotifIds.length >= 200) {
              _seenNotifIds.remove(_seenNotifIds.first);
            }
            _seenNotifIds.add(id);
            ref.invalidate(unreadCountProvider);

            // In-app feedback: sound + haptic for messages, only while the
            // user is actively in the app, and never for the chat they are
            // currently reading.
            if (!appResumed || n['read_at'] != null) continue;
            final kind = n['kind'] as String?;
            final payload = Map<String, dynamic>.from(
              n['payload'] as Map? ?? {},
            );
            final isMessageKind =
                kind == 'new_message' ||
                kind == 'official_message' ||
                kind == 'group_message';
            if (!isMessageKind) continue;
            final openConv = currentOpenConversationId.value;
            final openGroup = currentOpenGroupId.value;
            if (kind == 'group_message' && payload['group_id'] == openGroup) {
              continue;
            }
            if (kind != 'group_message' &&
                payload['conversation_id'] == openConv) {
              continue;
            }
            FeedbackService.alert();
          }
        });
  }

  @override
  Widget build(BuildContext context) {
    final profileAsync = ref.watch(myProfileProvider);

    // Inactivity warning banners (PRD Â§14): surfaced in-app from the
    // server-computed days-until-deletion.
    Widget? banner;
    profileAsync.maybeWhen(
      data: (p) {
        if (p != null && p.daysUntilDelete <= 10 && p.daysUntilDelete > 0) {
          banner = Material(
            color: JCColors.danger.withValues(alpha: 0.15),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                'Your account has ${p.daysUntilDelete} day(s) remaining '
                'before permanent deletion if you remain inactive.',
                style: const TextStyle(
                  color: JCColors.textPrimary,
                  fontSize: 13,
                ),
              ),
            ),
          );
        }
      },
      orElse: () {},
    );

    // System back: on Animals/Notifications/Mine the back button returns
    // to the Chats tab instead of exiting; only on Chats (the app root)
    // does back close the app.
    return PopScope(
      canPop: _tab == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        setState(() => _tab = 0);
      },
      child: Scaffold(
        // SafeArea: tabs were rendering under the status bar / display cutout
        // on tall and cutout devices.
        body: SafeArea(
          child: Column(
            children: [
              if (banner != null) banner!,
              Expanded(
                child: switch (_tab) {
                  0 => const ChatsTab(),
                  1 => const AnimalsTab(),
                  2 => const NotificationsScreen(),
                  _ => const MineTab(),
                },
              ),
            ],
          ),
        ),
        bottomNavigationBar: NavigationBar(
          backgroundColor: JCColors.surface,
          indicatorColor: JCColors.accentDim,
          selectedIndex: _tab,
          onDestinationSelected: (i) {
            if (i == _tab) return;
            FeedbackService.tabSwitch();
            setState(() => _tab = i);
            if (i == 2) ref.invalidate(unreadCountProvider);
          },
          destinations: [
            const NavigationDestination(
              icon: Icon(Icons.chat_bubble_outline),
              selectedIcon: Icon(Icons.chat_bubble),
              label: 'Chats',
            ),
            const NavigationDestination(
              icon: Icon(Icons.pets_outlined),
              selectedIcon: Icon(Icons.pets),
              label: 'Animals',
            ),
            NavigationDestination(
              icon: _notifIcon(Icons.notifications_none),
              selectedIcon: _notifIcon(Icons.notifications, selected: true),
              label: 'Notifications',
            ),
            const NavigationDestination(
              icon: Icon(Icons.person_outline),
              selectedIcon: Icon(Icons.person),
              label: 'Mine',
            ),
          ],
        ),
      ),
    );
  }

  /// Notifications icon with the live unread badge.
  Widget _notifIcon(IconData icon, {bool selected = false}) {
    final count = ref.watch(unreadCountProvider).value ?? 0;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Icon(icon, size: 24, color: selected ? JCColors.accent : null),
        if (count > 0)
          Positioned(
            right: -6,
            top: -4,
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: const BoxDecoration(
                color: JCColors.danger,
                shape: BoxShape.circle,
              ),
              constraints: const BoxConstraints(minWidth: 18),
              child: Text(
                count > 99 ? '99+' : '$count',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 9,
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
