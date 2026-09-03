import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../core/rpc.dart';

/// Private conversations after accepted talk requests.
class ChatService {
  final SupabaseClient _db = Supabase.instance.client;

  Future<List<ConversationView>> listConversations() async {
    final rows = await _db.rpc('list_my_conversations');
    return (rows as List).map((raw) {
      final j = Map<String, dynamic>.from(raw);
      final lm = j['last_message_at'];
      return ConversationView(
        id: j['conversation_id'] as String,
        otherId: j['partner_id'] as String? ?? '',
        otherDisplayId: j['partner_display_id'] as String? ?? '???',
        otherAnimal: j['partner_animal'] as String? ?? '',
        otherBio: j['partner_bio'] as String?,
        otherIsOnline: j['partner_is_online'] as bool? ?? false,
        lastMessageAt: lm == null
            ? null
            : DateTime.parse(lm as String).toLocal(),
        unreadCount: (j['unread_count'] as num?)?.toInt() ?? 0,
      );
    }).toList();
  }

  /// Heartbeat — call periodically while foregrounded + on launch to keep the
  /// user marked online. Cheap upsert, server-stamped.
  Future<void> heartbeat() => _db.rpc('heartbeat');

  /// Realtime message activity across ALL my private conversations.
  /// RLS-filtered: only rows I am a participant of ever arrive. The Chats
  /// tab listens so unread badges update the instant a message lands —
  /// no pull-to-refresh required.
  ///
  /// Bug B7: the old impl streamed `direct_messages` with `.limit(1)` as an
  /// activity proxy. That emits nothing for a user with zero messages and
  /// its semantics depend on which single row RLS returns. We instead watch
  /// the `conversations` row (one per thread, always present) for
  /// `last_message_at` changes — deterministic and works with an empty inbox.
  Stream<List<Map<String, dynamic>>> conversationActivityStream() =>
      _db.from('conversations').stream(primaryKey: ['id']).limit(1);

  /// Same as [conversationActivityStream] but for group messages.
  Stream<List<Map<String, dynamic>>> groupMessageActivityStream() =>
      _db.from('group_messages').stream(primaryKey: ['id']).limit(1);

  /// Marks my side read + clears new_message notifications for it.
  Future<void> markRead(String conversationId) => _db.rpc(
    'mark_conversation_read',
    params: {'p_conversation': conversationId},
  );

  /// Server-derived verification: is the OTHER participant the official
  /// admin ("Adam")? Never trust a client-side id list for this.
  Future<bool> isOfficialConversation(String conversationId) async {
    try {
      return await _db.rpc(
        'is_official_conversation',
        params: {'p_conversation': conversationId},
      ) as bool;
    } catch (_) {
      return false;
    }
  }

  Stream<List<DirectMessage>> messages(String conversationId) {
    return _db
        .from('direct_messages')
        .stream(primaryKey: ['id'])
        .eq('conversation_id', conversationId)
        // Server-side order: with only .limit(200) and no order, the limit
        // applies to an ARBITRARY 200 rows — on long histories the newest
        // messages could silently drop out of the chat.
        .order('created_at', ascending: false)
        .limit(200)
        .map((rows) {
          // Deterministic order — newest FIRST. Stream ordering is never
          // trusted; the reversed list renders index 0 at the bottom.
          final list = rows
              .map((r) => DirectMessage.fromJson(Map<String, dynamic>.from(r)))
              .toList();
          list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
          return list;
        });
  }

  /// Generates a stable client-side UUID per send. The bubble is keyed by it
  /// (B9) and the insert is idempotent server-side (0306) so a retry after a
  /// timeout returns the existing row instead of duplicating. Callers must
  /// pass the SAME id they use as the optimistic bubble key.
  String newClientMsgId() => const Uuid().v4();

  Future<String> send(
    String conversationId,
    String content, {
    String? replyTo,
    required String clientMsgId,
  }) async {
    final params = <String, dynamic>{
      'p_conversation': conversationId,
      'p_content': content,
      'p_reply_to': ?replyTo,
      'p_client_msg_id': clientMsgId,
    };
    // Legacy form without p_client_msg_id (pre-0306 server). Idempotency only
    // exists on the new path; the optimistic bubble is still reconciled by the
    // history refresh, so a retry cannot duplicate on the old server either.
    final legacy = <String, dynamic>{
      'p_conversation': conversationId,
      'p_content': content,
      'p_reply_to': ?replyTo,
    };
    return await Rpc.sendMessage(
      'send_direct_message',
      params: params,
      fallbackParams: legacy,
    );
  }

  /// Bug B10: keyset pagination. The live `.stream()` only buffers a window;
  /// this fetches an explicit older page by `created_at` so a 5 000-message
  /// history is reachable by scrolling up without re-downloading everything.
  Future<List<DirectMessage>> loadHistory(
    String conversationId, {
    DateTime? before,
    int limit = 50,
  }) async {
    var q = _db
        .from('direct_messages')
        .select()
        .eq('conversation_id', conversationId);
    if (before != null) {
      // Keyset pagination: strictly older than the oldest loaded row.
      // `.lt()` is a FILTER — it must be applied here, while the builder is
      // still a PostgrestFilterBuilder. order/limit turn it into a
      // TransformBuilder that no longer exposes `.lt()`.
      q = q.lt('created_at', before.toUtc().toIso8601String());
    }
    final rows = await q.order('created_at', ascending: false).limit(limit);
    return (rows as List)
        .map((r) => DirectMessage.fromJson(Map<String, dynamic>.from(r)))
        .toList();
  }

  /// Bug B8: collapse the 4 sequential round-trips that fired on every chat
  /// open (is_current_user_admin + is_official_conversation +
  /// list_conversations + get_my_profile) into one RPC returning the partner
  /// identity, online state, official flag, my role, unread count, and typing
  /// preference in a single response.
  Future<OpenConversationView?> openConversation(String conversationId) async {
    try {
      final rows = await _db.rpc(
        'open_conversation',
        params: {'p_conversation': conversationId},
      );
      final j = (rows as List).firstWhere(
        (_) => true,
        orElse: () => null,
      );
      if (j == null) return null;
      return OpenConversationView.fromJson(Map<String, dynamic>.from(j));
    } catch (_) {
      return null;
    }
  }

  /// React to a private message (WhatsApp model: one per user, upsert).
  /// Empty emoji removes my reaction.
  Future<void> react(String messageId, String emoji) => _db.rpc(
    'react_direct_message',
    params: {'p_message': messageId, 'p_emoji': emoji},
  );

  /// Live reaction stream for one conversation (reactions read-only via RLS).
  /// Map key: `<message_id>|<user_id>` -> emoji.
  Stream<Map<String, String>> reactions(String conversationId) {
    return _db
        .from('direct_message_reactions')
        .stream(primaryKey: ['id'])
        .eq('conversation_id', conversationId)
        .limit(2000)
        .map(
          (rows) => {
            for (final r in rows)
              if (r['message_id'] != null && r['user_id'] != null)
                '${r['message_id']}|${r['user_id']}':
                    (r['emoji'] as String?) ?? '',
          },
        );
  }

  /// I am typing: now rides the Realtime Broadcast channel (Phase 5.4 / B6),
  /// so it performs ZERO database writes and triggers no `conversations` row
  /// churn. See [RealtimeChat.sendTypingConversation]. The old `set_typing`
  /// RPC and `typing_a_until` / `typing_b_until` columns were dropped in
  /// migration 0309.
  ///
  /// Watch the partner's typing state via [RealtimeChat.onTypingConversation]
  /// instead of a Postgres Changes subscription on `conversations`.

  /// Documented policy: soft-deletes the thread for both participants.
  Future<void> deleteConversation(String conversationId) => _db.rpc(
    'delete_conversation',
    params: {'p_conversation': conversationId},
  );

  /// Sets the auto-delete interval for a conversation.
  /// Pass 'NULL' for off, or interval string like 'interval \'24 hours\''.
  Future<void> setConversationAutoDelete(
    String conversationId,
    String? interval,
  ) async {
    await _db.rpc(
      'set_conversation_auto_delete',
      params: {'p_conversation_id': conversationId, 'p_interval': interval},
    );
  }

  /// Edit MY OWN message — server enforces the 30-minute window and
  /// sender-only rule; the client is only cosmetic pre-checking.
  Future<void> editMessage(String messageId, String content) => _db.rpc(
    'edit_direct_message',
    params: {'p_message': messageId, 'p_content': content},
  );

  /// Delete MY OWN message (tombstone for both sides, content scrubbed
  /// server-side).
  Future<void> deleteMessage(String messageId) =>
      _db.rpc('delete_direct_message', params: {'p_message': messageId});

  /// Gets the auto-delete interval for a conversation.
  /// Returns null if off, or interval string.
  Future<String?> getConversationAutoDelete(String conversationId) async {
    final result = await _db.rpc(
      'get_conversation_auto_delete',
      params: {'p_conversation_id': conversationId},
    );
    return result as String?;
  }
}

class ConversationView {
  final String id;
  final String otherId;
  final String otherDisplayId;
  final String otherAnimal;
  final String? otherBio;
  final bool otherIsOnline;
  final DateTime? lastMessageAt;
  final int unreadCount;

  const ConversationView({
    required this.id,
    required this.otherId,
    required this.otherDisplayId,
    required this.otherAnimal,
    this.otherBio,
    this.otherIsOnline = false,
    this.lastMessageAt,
    this.unreadCount = 0,
  });
}

class DirectMessage {
  final String id;
  final String senderId;
  final String content;
  final DateTime createdAt;
  final DateTime? editedAt;
  final DateTime? deletedAt;
  final String? replyToId;
  final String? clientMsgId;
  final DateTime? expiresAt;

  const DirectMessage({
    required this.id,
    required this.senderId,
    required this.content,
    required this.createdAt,
    this.editedAt,
    this.deletedAt,
    this.replyToId,
    this.clientMsgId,
    this.expiresAt,
  });

  bool get isDeleted => deletedAt != null;

  factory DirectMessage.fromJson(Map<String, dynamic> j) => DirectMessage(
    id: j['id'] as String,
    senderId: j['sender_id'] as String,
    content: j['content'] as String,
    createdAt: DateTime.parse(j['created_at'] as String).toLocal(),
    editedAt: j['edited_at'] == null
        ? null
        : DateTime.parse(j['edited_at'] as String).toLocal(),
    deletedAt: j['deleted_at'] == null
        ? null
        : DateTime.parse(j['deleted_at'] as String).toLocal(),
    replyToId: j['reply_to_id'] as String?,
    clientMsgId: j['client_msg_id'] as String?,
    expiresAt: j['expires_at'] == null
        ? null
        : DateTime.parse(j['expires_at'] as String).toLocal(),
  );
}

class OpenConversationView {
  final String partnerId;
  final String partnerDisplayId;
  final String partnerAnimal;
  final String? partnerBio;
  final bool partnerIsOnline;
  final bool isOfficial;
  final bool amAdmin;
  final int unreadCount;
  final bool typingEnabled;
  // MY OWN typing preference (profiles.typing_indicator_enabled) — folded into
  // this single RPC so chat open no longer needs a separate get_my_profile
  // round-trip (B8). `typingEnabled` above is the PARTNER's preference.
  final bool myTypingEnabled;

  const OpenConversationView({
    required this.partnerId,
    required this.partnerDisplayId,
    required this.partnerAnimal,
    this.partnerBio,
    this.partnerIsOnline = false,
    this.isOfficial = false,
    this.amAdmin = false,
    this.unreadCount = 0,
    this.typingEnabled = true,
    this.myTypingEnabled = true,
  });

  factory OpenConversationView.fromJson(Map<String, dynamic> j) =>
      OpenConversationView(
        partnerId: j['partner_id'] as String? ?? '',
        partnerDisplayId: j['partner_display_id'] as String? ?? '???',
        partnerAnimal: j['partner_animal'] as String? ?? '',
        partnerBio: j['partner_bio'] as String?,
        partnerIsOnline: j['partner_is_online'] as bool? ?? false,
        isOfficial: j['is_official'] as bool? ?? false,
        amAdmin: j['am_admin'] as bool? ?? false,
        unreadCount: (j['unread_count'] as num?)?.toInt() ?? 0,
        typingEnabled: j['typing_enabled'] as bool? ?? true,
        myTypingEnabled: j['my_typing_enabled'] as bool? ?? true,
      );
}
