import 'package:supabase_flutter/supabase_flutter.dart';

/// Phase 5.1 — Realtime Broadcast transport for live message fan-out and
/// typing indicators, replacing the heavy Postgres Changes round-trips.
///
/// Each conversation / group gets a PRIVATE broadcast channel (authenticated
/// only; conversation ids are unguessable UUIDs). The channel is the FAST
/// PATH: messages and typing events arrive in well under 100 ms. Postgres
/// Changes remains the reconciliation fallback (see [ChatService.messages] /
/// [GroupService.messages]), so a missed or delayed broadcast can never lose a
/// message — it simply arrives a beat later via the postgres_changes stream.
///
/// Fail-closed: every send is wrapped so a channel/network hiccup is invisible
/// to the user. A typing or broadcast failure degrades to the postgres_changes
/// path, never to a crash or a stack trace.
class RealtimeChat {
  static final RealtimeChat _instance = RealtimeChat._();
  factory RealtimeChat() => _instance;
  RealtimeChat._();

  final SupabaseClient _db = Supabase.instance.client;
  final Map<String, RealtimeChannel> _channels = {};

  RealtimeChannel _channel(String name) {
    // Private: Supabase enforces an authenticated JWT on subscribe, so only
    // signed-in clients can join. Conversation/group ids are random UUIDs,
    // so a non-participant would also have to know the exact id.
    return _channels.putIfAbsent(
      name,
      () => _db
          .channel(name, opts: const RealtimeChannelConfig(private: true))
          ..subscribe(),
    );
  }

  /// DM channel `dm:{conversationId}`.
  RealtimeChannel conversationChannel(String conversationId) =>
      _channel('dm:$conversationId');

  /// Group channel `grp:{groupId}`.
  RealtimeChannel groupChannel(String groupId) => _channel('grp:$groupId');

  // ── Typing (B6): zero DB writes, zero RLS eval, no conversations churn ──

  void sendTypingConversation(String conversationId) {
    try {
      conversationChannel(conversationId)
          .sendBroadcastMessage(event: 'typing', payload: const {});
    } catch (_) {
      // Best-effort: a typing hiccup must never surface to the user.
    }
  }

  RealtimeChannel onTypingConversation(
    String conversationId,
    void Function() onTyping,
  ) =>
      conversationChannel(conversationId).onBroadcast(
        event: 'typing',
        callback: (_) => onTyping(),
      );

  void sendTypingGroup(String groupId) {
    try {
      groupChannel(groupId)
          .sendBroadcastMessage(event: 'typing', payload: const {});
    } catch (_) {}
  }

  RealtimeChannel onTypingGroup(
    String groupId,
    void Function() onTyping,
  ) =>
      groupChannel(groupId).onBroadcast(
        event: 'typing',
        callback: (_) => onTyping(),
      );

  // ── Message fast-path (Phase 5.1) ───────────────────────────────────────
  //
  // The sender broadcasts the freshly-inserted row (keyed by its server id +
  // the stable client_msg_id) so the receiver can upsert it immediately. The
  // postgres_changes stream delivers the same row shortly after and dedups by
  // id, so there is never a duplicate.

  void broadcastConversationMessage(
    String conversationId,
    Map<String, dynamic> payload,
  ) {
    try {
      conversationChannel(conversationId)
          .sendBroadcastMessage(event: 'message', payload: payload);
    } catch (_) {}
  }

  RealtimeChannel onConversationMessage(
    String conversationId,
    void Function(Map<String, dynamic> payload) onMessage,
  ) =>
      conversationChannel(conversationId).onBroadcast(
        event: 'message',
        callback: onMessage,
      );

  void broadcastGroupMessage(
    String groupId,
    Map<String, dynamic> payload,
  ) {
    try {
      groupChannel(groupId)
          .sendBroadcastMessage(event: 'message', payload: payload);
    } catch (_) {}
  }

  RealtimeChannel onGroupMessage(
    String groupId,
    void Function(Map<String, dynamic> payload) onMessage,
  ) =>
      groupChannel(groupId).onBroadcast(
        event: 'message',
        callback: onMessage,
      );

  // ── D2: surface a system notice to BOTH parties when the auto-delete timer
  // changes. Carried as a broadcast event (not persisted) so it shows on the
  // receiving device immediately; the dialog already states the change applies
  // to new messages only. ──────────────────────────────────────────────────

  void broadcastTimerChanged(String conversationId, String label) {
    try {
      conversationChannel(conversationId).sendBroadcastMessage(
        event: 'timer_changed',
        payload: {'label': label},
      );
    } catch (_) {}
  }

  RealtimeChannel onTimerChanged(
    String conversationId,
    void Function(String label) onChanged,
  ) =>
      conversationChannel(conversationId).onBroadcast(
        event: 'timer_changed',
        callback: (p) => onChanged((p['label'] as String?) ?? ''),
      );

  /// Unsubscribe + forget a channel. Call from the screen's [dispose] so the
  /// singleton does not leak channels for closed threads.
  void closeConversation(String conversationId) => _close('dm:$conversationId');
  void closeGroup(String groupId) => _close('grp:$groupId');

  void _close(String name) {
    final ch = _channels.remove(name);
    if (ch != null) {
      try {
        _db.removeChannel(ch);
      } catch (_) {}
    }
  }
}
