import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/router.dart' show rootNavigatorKey;
import 'account_deleted_dialog.dart';

/// Listens to the current user's profile row via Supabase Realtime.
/// - hard delete (row gone) → sign out + redirect
/// - suspended/banned → sign out + redirect
/// Deletion is detected by the Realtime DELETE event on profiles (cascade from
/// the auth.users delete) and, as a backstop, by the 401 the next authenticated
/// call returns once the session is dead. There is no soft-delete state anymore.
class KickOutListener extends StatefulWidget {
  const KickOutListener({super.key, required this.child});

  final Widget child;

  @override
  State<KickOutListener> createState() => _KickOutListenerState();
}

class _KickOutListenerState extends State<KickOutListener> {
  RealtimeChannel? _channel;
  StreamSubscription<AuthState>? _authSub;
  String? _lastUserId;

  @override
  void initState() {
    super.initState();
    _lastUserId = Supabase.instance.client.auth.currentSession?.user.id;
    _subscribe(_lastUserId);
    // WHY: an already-signed-in user who was soft-deleted while the app was
    // closed has no Realtime row-change to fire — the cold start is the only
    // chance to notice. Cheap maybeSingle() on an indexed pk.
    if (_lastUserId != null) _checkDeletedOnStartup();
    // A user who signs in AFTER app start never existed at initState time —
    // resubscribe whenever the signed-in user changes. Token refreshes keep
    // the same user and are ignored.
    _authSub = Supabase.instance.client.auth.onAuthStateChange.listen((s) {
      final userId = s.session?.user.id;
      if (userId == _lastUserId) return;
      _lastUserId = userId;
      _subscribe(userId);
      if (userId != null) _checkDeletedOnStartup();
    });
  }

  /// Check if the account is already gone when the app starts / after login.
  /// A hard-deleted user has no profile row (it cascaded away with auth.users);
  /// RLS lets the caller read only their own row, so a null result means gone.
  Future<void> _checkDeletedOnStartup() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return;

    try {
      final data = await Supabase.instance.client
          .from('profiles')
          .select('id')
          .eq('id', user.id)
          .maybeSingle();

      if (data == null) {
        _showDeletedDialog();
      }
    } catch (_) {
      // Profile fetch failed — ignore, realtime will catch changes
    }
  }

  void _subscribe(String? userId) {
    _teardownChannel();
    if (userId == null) return;

    _channel = Supabase.instance.client
        .channel('kick_out_$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'profiles',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'id',
            value: userId,
          ),
          callback: _onProfileChange,
        )
        .subscribe();
  }

  /// unsubscribe() alone leaves the channel registered on the client; the
  /// handle must be removed or it leaks (and re-subscribing stacks channels).
  void _teardownChannel() {
    final ch = _channel;
    if (ch == null) return;
    _channel = null;
    Supabase.instance.client.removeChannel(ch);
  }

  void _onProfileChange(PostgresChangePayload payload) {
    // Hard delete emits a DELETE event with no new row → blocking dialog.
    if (payload.eventType == PostgresChangeEvent.delete) {
      _showDeletedDialog();
      return;
    }

    final newRecord = payload.newRecord;

    // Suspended or banned → sign out.
    final status = newRecord['status'] as String?;
    if (status == 'suspended' || status == 'banned') {
      _signOutAndRedirect('Your account has been $status.');
    }
  }

  void _showDeletedDialog() {
    _teardownChannel();

    // This widget sits ABOVE MaterialApp — its own context has no Navigator.
    // The root navigator (below MaterialApp) is the only valid anchor.
    final ctx = rootNavigatorKey.currentContext;
    if (ctx == null) return;
    AccountDeletedDialog.show(ctx);
  }

  void _signOutAndRedirect(String reason) async {
    _teardownChannel();

    try {
      await Supabase.instance.client.auth.signOut();
    } catch (_) {}

    final ctx = rootNavigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) return;

    ScaffoldMessenger.of(ctx).showSnackBar(
      SnackBar(
        content: Text(reason),
        backgroundColor: Colors.red,
        duration: const Duration(seconds: 5),
      ),
    );

    Navigator.of(ctx).popUntil((route) => route.isFirst);
  }

  @override
  void dispose() {
    _teardownChannel();
    _authSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
