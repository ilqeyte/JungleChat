import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/router.dart';
import '../features/update/update_flow.dart';
import '../features/update/update_gate.dart';

/// Push + local notifications.
///
/// * Permission is requested once, after login (never at cold launch).
/// * FCM token is saved to the server so the push worker can reach the user.
/// * Foreground messages surface as local notifications (system tray).
/// * Background/terminated messages are delivered by FCM itself.
/// * TAPPING a notification routes somewhere useful. App-update
///   notifications open the in-app update screen — this is why the push
///   worker stamps every message with `data.kind`.
class NotificationService {
  static final _local = FlutterLocalNotificationsPlugin();
  static bool _localReady = false;

  /// Messages that arrived while the app was FOREGROUND. They are held
  /// here (no system notification, no sound — the in-app realtime stream
  /// handles sound/haptic) and flushed to the system tray the moment the
  /// user leaves or minimizes the app.
  static final List<RemoteMessage> _foregroundQueue = [];

  // Monotonic counter so distinct notifications never collide on Android's
  // notification id (int, >= 0). The previous `n.hashCode` collapsed every
  // privacy-templated "An animal sent you a message." into the same slot,
  // so a burst of DMs surfaced as one notification.
  static int _nextId = 0;
  static int _newNotifId() {
    _nextId = (_nextId + 1) & 0x7FFFFFFF;
    return _nextId == 0 ? 1 : _nextId;
  }

  static const _channel = AndroidNotificationChannel(
    'junglechat_messages',
    'Messages & requests',
    description: 'New messages, talk requests and alerts.',
    importance: Importance.high,
  );

  @pragma('vm:entry-point')
  static Future<void> backgroundHandler(RemoteMessage message) async {
    await Firebase.initializeApp();
    await _ensureLocal();
    final n = message.notification;
    if (n != null) {
      await _local.show(
        id: _newNotifId(),
        title: n.title ?? 'JungleChat',
        body: n.body ?? '',
        notificationDetails: _details(),
        payload: _payloadFor(message),
      );
    }
  }

  static NotificationDetails _details() => NotificationDetails(
    android: AndroidNotificationDetails(
      _channel.id,
      _channel.name,
      channelDescription: _channel.description,
      importance: Importance.high,
      priority: Priority.high,
    ),
  );

  /// Serialised `data` block, so a tap on a local notification knows where
  /// to route (e.g. `{"kind":"app_update"}`).
  static String? _payloadFor(RemoteMessage message) {
    if (message.data.isEmpty) return null;
    try {
      return jsonEncode(message.data);
    } catch (_) {
      return null;
    }
  }

  static Future<void> _ensureLocal() async {
    if (_localReady) return;
    await _local.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/launcher_icon'),
      ),
      // Taps on locally shown notifications (foreground delivery).
      onDidReceiveNotificationResponse: _onNotificationTapped,
    );
    await _local
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(_channel);
    _localReady = true;
  }

  /// Tap on a notification our code showed (app was in the foreground).
  /// Tap on a notification our code showed (app was in the foreground).
  static void _onNotificationTapped(NotificationResponse response) {
    _route(
      _kindFromPayload(response.payload),
      _dataFromPayload(response.payload),
    );
  }

  static String? _kindFromPayload(String? payload) {
    if (payload == null || payload.isEmpty) return null;
    try {
      return (jsonDecode(payload) as Map<String, dynamic>)['kind'] as String?;
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic>? _dataFromPayload(String? payload) {
    if (payload == null || payload.isEmpty) return null;
    try {
      return jsonDecode(payload) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// FCM message whose notification was tapped — app was in the background,
  /// or the app was cold-started BY the tap (getInitialMessage in main).
  static void handleRemoteMessage(RemoteMessage message) {
    _route(message.data['kind']?.toString(), message.data);
  }

  /// Cold start: app launched from terminated by a notification tap.
  static Future<void> handleInitialMessage() async {
    final msg = await FirebaseMessaging.instance.getInitialMessage();
    if (msg == null) return;
    _route(msg.data['kind']?.toString(), msg.data);
  }

  static void _route(String? kind, Map<String, dynamic>? data) {
    switch (kind) {
      case 'app_update':
        // Re-check and present: required releases hand over to the gate's
        // blocking screen; optional ones open the /update page. The page
        // re-verifies against the installed build, so a stale tap on a
        // release the user already has shows "up to date", not a download.
        _openWhenReady(() => UpdateFlow.checkAndPresent(feedback: true));
        break;
      case 'new_message':
      case 'official_message':
        final cid = data?['conversation_id']?.toString();
        if (cid != null && cid.isNotEmpty) {
          _openWhenReady(() => appRouter.push('/chat/$cid'));
        }
        break;
      case 'group_message':
        final gid = data?['group_id']?.toString();
        if (gid != null && gid.isNotEmpty) {
          _openWhenReady(() => appRouter.push('/group/$gid'));
        }
        break;
      case 'group_added':
        final gid = data?['group_id']?.toString();
        if (gid != null && gid.isNotEmpty) {
          _openWhenReady(() => appRouter.push('/group/$gid'));
        }
        break;
      case 'group_invitation':
        _openWhenReady(() => appRouter.push('/notifications'));
        break;
    }
  }

  /// Notification taps can arrive before the app's router is mounted (cold
  /// start). Wait for UpdateGate to finish its first check, then navigate.
  static void _openWhenReady(void Function() go) {
    () async {
      try {
        await UpdateGate.ready.timeout(const Duration(seconds: 10));
      } catch (_) {}
      try {
        go();
      } catch (_) {}
    }();
  }

  /// Call once after login. Requests permission, saves the FCM token, and
  /// wires foreground handling. Safe to call repeatedly.
  ///
  /// NOT idempotent by nature: the three stream listeners below would stack
  /// one copy per call (ensureReady fires on every myProfileProvider
  /// re-emission — settings change, refetch), so each message then queues N
  /// times and N duplicate tray notifications appear on background. A single
  /// in-flight/completed future is therefore reused for the whole session;
  /// a failed attempt clears it so the next emission can retry.
  static Future<void>? _ensureReadyAttempt;
  static Future<void> ensureReady() {
    if (!Platform.isAndroid) return Future.value();
    final attempt = _ensureReadyAttempt;
    if (attempt != null) return attempt;
    final fresh = _ensureReadyImpl();
    _ensureReadyAttempt = fresh;
    fresh.catchError((_) => _ensureReadyAttempt = null);
    return fresh;
  }

  static Future<void> _ensureReadyImpl() async {
    await _ensureLocal();

    final messaging = FirebaseMessaging.instance;

    // The system permission prompt (Android 13+ / iOS).
    await messaging.requestPermission(provisional: false);

    // Android 13 notification runtime permission via local notifications.
    await _local
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();

    final token = await messaging.getToken();
    if (token != null) {
      await _saveToken(token);
    }
    messaging.onTokenRefresh.listen((t) => _saveToken(t));

    /// App open, user using it: HOLD the message (no tray notification, no
    /// sound here). It becomes a real system notification when the user
    /// leaves the app — see [presentQueuedOnBackground]. The in-app new
    /// message sound/haptic comes from the HomeShell realtime stream.
    FirebaseMessaging.onMessage.listen((message) {
      // WHY: cap the foreground queue. A long foreground session otherwise
      // accumulates every RemoteMessage + payload forever (it only drains on
      // background). Drop the oldest entries once we hit the limit.
      _foregroundQueue.add(message);
      if (_foregroundQueue.length > 20) {
        _foregroundQueue.removeRange(0, _foregroundQueue.length - 20);
      }
    });

    // Tapped a notification while the app was backgrounded.
    FirebaseMessaging.onMessageOpenedApp.listen(handleRemoteMessage);
  }

  /// Called when the app leaves the foreground (paused/detached): every
  /// message that arrived while the user was inside the app is now shown
  /// as a real system notification — available on the tray / lock screen.
  static Future<void> presentQueuedOnBackground() async {
    if (_foregroundQueue.isEmpty) return;
    await _ensureLocal();
    final queued = List<RemoteMessage>.from(_foregroundQueue);
    _foregroundQueue.clear();
    for (final message in queued) {
      final n = message.notification;
      if (n == null) continue;
      try {
        await _local.show(
          id: _newNotifId(),
          title: n.title ?? 'JungleChat',
          body: n.body ?? '',
          notificationDetails: _details(),
          payload: _payloadFor(message),
        );
      } catch (_) {}
    }
  }

  static Future<void> _saveToken(String token) async {
    try {
      await Supabase.instance.client.rpc(
        'upsert_push_token',
        params: {'p_token': token, 'p_platform': 'android'},
      );
    } catch (_) {
      // Token save failures are retried on next launch via ensureReady.
    }
  }
}
