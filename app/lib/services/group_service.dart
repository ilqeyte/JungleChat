import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../core/rpc.dart';

/// Group chat service — manages groups, members, and group messages.
class GroupService {
  final SupabaseClient _db = Supabase.instance.client;

  // ── List my groups ────────────────────────────────────────────────────────

  Future<List<GroupView>> listMyGroups() async {
    final rows = await _db.rpc('list_my_groups');
    return (rows as List).map((raw) {
      final j = Map<String, dynamic>.from(raw);
      final lm = j['last_message_at'];
      return GroupView(
        id: j['group_id'] as String,
        name: j['group_name'] as String,
        memberCount: (j['member_count'] as num?)?.toInt() ?? 0,
        lastMessage: j['last_message'] as String?,
        lastMessageAt: lm == null
            ? null
            : DateTime.parse(lm as String).toLocal(),
        lastSenderId: j['last_sender_id'] as String?,
        unreadCount: (j['unread_count'] as num?)?.toInt() ?? 0,
      );
    }).toList();
  }

  // ── Create group ─────────────────────────────────────────────────────────

  Future<String> createGroup(String name, List<String> memberIds) async {
    return await _db.rpc(
      'create_group',
      params: {'p_name': name, 'p_member_ids': memberIds},
    ) as String;
  }

  // ── Send group message ───────────────────────────────────────────────────

  Future<String> sendGroupMessage(
    String groupId,
    String content, {
    String? replyTo,
    required String clientMsgId,
  }) async {
    final params = <String, dynamic>{
      'p_group_id': groupId,
      'p_content': content,
      'p_reply_to': ?replyTo,
      'p_client_msg_id': clientMsgId,
    };
    final legacy = <String, dynamic>{
      'p_group_id': groupId,
      'p_content': content,
      'p_reply_to': ?replyTo,
    };
    return await Rpc.sendMessage(
      'send_group_message',
      params: params,
      fallbackParams: legacy,
    );
  }

  /// Generates a stable client-side UUID per send — mirrors [ChatService].
  /// The bubble is keyed by it (B9) and the insert is idempotent server-side
  /// (0306) so a retry after a timeout returns the existing row instead of
  /// duplicating. Callers must pass the SAME id they use as the optimistic
  /// bubble key.
  String newClientMsgId() => const Uuid().v4();

  /// React to a group message (WhatsApp model: one per user, upsert).
  /// Empty emoji removes my reaction.
  Future<void> reactGroupMessage(String messageId, String emoji) => _db.rpc(
    'react_group_message',
    params: {'p_message': messageId, 'p_emoji': emoji},
  );

  /// Live reaction stream for one group (reactions read-only via RLS).
  Stream<Map<String, String>> reactions(String groupId) {
    return _db
        .from('group_message_reactions')
        .stream(primaryKey: ['id'])
        .eq('group_id', groupId)
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

  /// Edit MY OWN group message — server enforces the 30-minute window,
  /// sender-only rule and current membership.
  Future<void> editGroupMessage(String messageId, String content) => _db.rpc(
    'edit_group_message',
    params: {'p_message': messageId, 'p_content': content},
  );

  /// Delete MY OWN group message (tombstone, content scrubbed server-side).
  Future<void> deleteGroupMessage(String messageId) =>
      _db.rpc('delete_group_message', params: {'p_message': messageId});

  // ── Real-time message stream ─────────────────────────────────────────────

  Stream<List<GroupMessage>> messages(String groupId) {
    return _db
        .from('group_messages')
        .stream(primaryKey: ['id'])
        .eq('group_id', groupId)
        // Server-side order: see chat_service.messages — an unordered
        // .limit(200) can silently drop the newest rows on long histories.
        .order('created_at', ascending: false)
        .limit(200)
        .map((rows) {
          final list = rows
              .map((r) => GroupMessage.fromJson(Map<String, dynamic>.from(r)))
              .toList();
          list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
          return list;
        });
  }

  // ── Mark group read ─────────────────────────────────────────────────────

  Future<void> markRead(String groupId) =>
      _db.rpc('mark_group_read', params: {'p_group_id': groupId});

  // ── Get group info ──────────────────────────────────────────────────────

  Future<GroupInfo> getGroupInfo(String groupId) async {
    final result = await _db.rpc(
      'get_group_info',
      params: {'p_group_id': groupId},
    );
    final j = Map<String, dynamic>.from(result as Map);
    final members = (j['members'] as List?)?.map((m) {
      final mj = Map<String, dynamic>.from(m);
      return GroupMember(
        userId: mj['user_id'] as String,
        role: mj['role'] as String,
        animal: mj['animal'] as String? ?? '',
        displayAnimalId: mj['display_animal_id'] as String? ?? '',
        bio: mj['bio'] as String?,
        isOnline: mj['is_online'] as bool? ?? false,
        joinedAt: DateTime.parse(mj['joined_at'] as String).toLocal(),
      );
    }).toList();
    return GroupInfo(
      id: j['id'] as String,
      name: j['name'] as String,
      creatorId: j['creator_id'] as String,
      createdAt: DateTime.parse(j['created_at'] as String).toLocal(),
      members: members ?? [],
    );
  }

  // ── Add members ────────────────────────────────────────────────────────

  Future<int> addMembers(String groupId, List<String> memberIds) async {
    return await _db.rpc(
      'add_group_members',
      params: {'p_group_id': groupId, 'p_member_ids': memberIds},
    ) as int;
  }

  // ── Remove member / leave group ────────────────────────────────────────

  /// Returns true if the group was dissolved (creator left or <2 members).
  Future<bool> removeMember(String groupId, String userId) async {
    return await _db.rpc(
      'remove_group_member',
      params: {'p_group_id': groupId, 'p_user_id': userId},
    ) as bool;
  }

  /// Accept a group invitation. Returns the joined group's id so the
  /// caller can open the group chat straight away.
  Future<String> acceptGroupInvitation(String notificationId) async {
    return await _db.rpc(
      'accept_group_invitation',
      params: {'p_notification_id': notificationId},
    ) as String;
  }

  /// Reject/ignore a group invitation.
  Future<void> rejectGroupInvitation(String notificationId) async {
    await _db.rpc(
      'reject_group_invitation',
      params: {'p_notification_id': notificationId},
    );
  }

  // ── Update group name ─────────────────────────────────────────────────

  Future<void> updateGroupName(String groupId, String newName) async {
    await _db.rpc(
      'update_group_name',
      params: {'p_group_id': groupId, 'p_new_name': newName},
    );
  }

  // ── Auto-delete timer ──────────────────────────────────────────────────

  /// Sets the auto-delete interval for a group. Admin only.
  /// Pass 'NULL' for off, or interval string like 'interval \'24 hours\''.
  Future<void> setGroupAutoDelete(String groupId, String? interval) async {
    await _db.rpc(
      'set_group_auto_delete',
      params: {'p_group_id': groupId, 'p_interval': interval},
    );
  }

  /// Gets the auto-delete interval for a group.
  /// Returns null if off, or interval string.
  Future<String?> getGroupAutoDelete(String groupId) async {
    final result = await _db.rpc(
      'get_group_auto_delete',
      params: {'p_group_id': groupId},
    );
    return result as String?;
  }
}

// ── Models ──────────────────────────────────────────────────────────────────

class GroupView {
  final String id;
  final String name;
  final int memberCount;
  final String? lastMessage;
  final DateTime? lastMessageAt;
  final String? lastSenderId;
  final int unreadCount;

  const GroupView({
    required this.id,
    required this.name,
    required this.memberCount,
    this.lastMessage,
    this.lastMessageAt,
    this.lastSenderId,
    this.unreadCount = 0,
  });
}

class GroupMessage {
  final String id;
  final String senderId;
  final String content;
  final DateTime createdAt;
  final bool isMine;
  final DateTime? editedAt;
  final DateTime? deletedAt;
  final String? replyToId;
  final String? clientMsgId;

  const GroupMessage({
    required this.id,
    required this.senderId,
    required this.content,
    required this.createdAt,
    required this.isMine,
    this.editedAt,
    this.deletedAt,
    this.replyToId,
    this.clientMsgId,
  });

  bool get isDeleted => deletedAt != null;

  factory GroupMessage.fromJson(Map<String, dynamic> j) => GroupMessage(
    id: j['id'] as String,
    senderId: j['sender_id'] as String,
    content: j['content'] as String,
    createdAt: DateTime.parse(j['created_at'] as String).toLocal(),
    isMine: j['is_mine'] as bool? ?? false,
    editedAt: j['edited_at'] == null
        ? null
        : DateTime.parse(j['edited_at'] as String).toLocal(),
    deletedAt: j['deleted_at'] == null
        ? null
        : DateTime.parse(j['deleted_at'] as String).toLocal(),
    replyToId: j['reply_to_id'] as String?,
    clientMsgId: j['client_msg_id'] as String?,
  );
}

class GroupInfo {
  final String id;
  final String name;
  final String creatorId;
  final DateTime createdAt;
  final List<GroupMember> members;

  const GroupInfo({
    required this.id,
    required this.name,
    required this.creatorId,
    required this.createdAt,
    required this.members,
  });

  bool isAdmin(String userId) =>
      members.any((m) => m.userId == userId && m.role == 'admin');
}

class GroupMember {
  final String userId;
  final String role;
  final String animal;
  final String displayAnimalId;
  final String? bio;
  final bool isOnline;
  final DateTime joinedAt;

  const GroupMember({
    required this.userId,
    required this.role,
    required this.animal,
    required this.displayAnimalId,
    this.bio,
    this.isOnline = false,
    required this.joinedAt,
  });
}
