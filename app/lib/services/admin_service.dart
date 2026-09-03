import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/rpc.dart';

/// Adam admin client. Every call hits a server-side RPC that independently
/// verifies the admin role. This class is convenience only — it grants
/// nothing by itself.
class AdminService {
  final SupabaseClient _db = Supabase.instance.client;

  // ── Reports ──────────────────────────────────────────────────────────────

  Future<List<ReportView>> listReports(String status) async {
    final rows = await _db.rpc(
      'admin_list_reports',
      params: {'p_status': status, 'p_limit': 100},
    );
    return (rows as List)
        .map((r) => ReportView.fromJson(Map<String, dynamic>.from(r)))
        .toList();
  }

  Future<void> resolveReport(int reportId, String status, String note) =>
      _db.rpc(
        'admin_resolve_report',
        params: {'p_report': reportId, 'p_status': status, 'p_note': note},
      );

  // ── Audit ────────────────────────────────────────────────────────────────

  Future<List<AuditRow>> auditLog() async {
    final rows = await _db.rpc(
      'admin_list_audit_log',
      params: {'p_limit': 200},
    );
    return (rows as List)
        .map((r) => AuditRow.fromJson(Map<String, dynamic>.from(r)))
        .toList();
  }

  // ── User management ──────────────────────────────────────────────────────

  Future<List<AdminUser>> listUsers() async {
    final rows = await _db.rpc('admin_list_users');
    return (rows as List)
        .map((r) => AdminUser.fromJson(Map<String, dynamic>.from(r)))
        .toList();
  }

  Future<void> suspendUser(String userId, String status, String reason) =>
      _db.rpc(
        'admin_suspend_user',
        params: {'p_user_id': userId, 'p_status': status, 'p_reason': reason},
      );

  /// PERMANENTLY deletes the account (auth identity + cascaded content).
  ///
  /// Runs through the admin-hard-delete-user Edge Function because auth
  /// identities cannot be removed from SQL on hosted Supabase. Irreversible —
  /// one action, no undo window.
  Future<void> hardDeleteUser(String userId) async {
    try {
      final res = await _db.functions.invoke(
        'admin-hard-delete-user',
        body: {'userId': userId},
      );
      final status = res.status;
      if (status != 200) {
        debugPrint('admin-hard-delete-user failed: HTTP $status ${res.data}');
        // Surface the server's opaque code so failures are diagnosable.
        // Previously a missing/non-2xx response collapsed into the generic
        // "Something went wrong.", hiding NOT_ADMIN, DELETE_FAILED, a stale
        // Edge Function, and a missing function behind one identical message.
        final code = (res.data is Map)
            ? (res.data as Map)['error']?.toString()
            : null;
        throw Exception('code=${code ?? 'HTTP_$status'}');
      }
    } catch (e) {
      debugPrint('hardDeleteUser error: $e');
      rethrow;
    }
  }

  // ── Official support channel ───────────────────────────────────────────────

  /// Opens (or returns) the support thread with a user.
  Future<String> openSupportChat(String userId) async =>
      await _db.rpc('admin_open_support_chat', params: {'p_user_id': userId})
          as String;

  /// Support inbox: threads, unread counts, partner identities.
  Future<List<SupportConversation>> listSupportConversations() async {
    final rows = await _db.rpc('admin_list_support_conversations');
    return (rows as List)
        .map((r) => SupportConversation.fromJson(Map<String, dynamic>.from(r)))
        .toList();
  }

  Future<void> markSupportRead(String conversationId) => _db.rpc(
    'admin_mark_support_read',
    params: {'p_conversation': conversationId},
  );

  /// Sends a message in the official channel (audited server-side).
  /// [replyTo] must be a message in the same thread (validated server-side).
  /// [clientMsgId] is the same stable id the client uses as the optimistic
  /// bubble key (B9) — the server insert is idempotent on it (0306).
  Future<String> sendSupportMessage(
    String conversationId,
    String content, {
    String? replyTo,
    required String clientMsgId,
  }) async => await Rpc.sendMessage(
    'admin_send_support_message',
    params: {
      'p_conversation': conversationId,
      'p_content': content,
      'p_reply_to': ?replyTo,
      'p_client_msg_id': clientMsgId,
    },
    fallbackParams: {
      'p_conversation': conversationId,
      'p_content': content,
      'p_reply_to': ?replyTo,
    },
  );

  // ── Auth ─────────────────────────────────────────────────────────────────

  Future<void> signInAdmin(String email, String password) async {
    final res = await _db.auth.signInWithPassword(
      email: email,
      password: password,
    );
    if (res.session == null) throw Exception('code=INVALID_CREDENTIALS');
  }
}

// ── Data classes ───────────────────────────────────────────────────────────

class AdminUser {
  final String userId;
  final String? animal;
  final int? animalNumber;
  final String? displayAnimalId;
  final String? status;
  final bool openToTalk;
  final DateTime? lastActiveAt;
  final DateTime createdAt;

  const AdminUser({
    required this.userId,
    this.animal,
    this.animalNumber,
    this.displayAnimalId,
    this.status,
    required this.openToTalk,
    this.lastActiveAt,
    required this.createdAt,
  });

  factory AdminUser.fromJson(Map<String, dynamic> j) => AdminUser(
    userId: j['user_id'] as String,
    animal: j['animal'] as String?,
    animalNumber: j['animal_number'] as int?,
    displayAnimalId: j['display_animal_id'] as String?,
    status: j['status'] as String?,
    openToTalk: j['open_to_talk'] as bool? ?? true,
    lastActiveAt: j['last_active_at'] != null
        ? DateTime.tryParse(j['last_active_at'] as String)
        : null,
    createdAt: DateTime.parse(j['created_at'] as String),
  );

  String get displayId =>
      displayAnimalId ??
      (animal != null ? '$animal ${animalNumber ?? ''}' : 'Unknown');

  bool get isOnline {
    if (lastActiveAt == null) return false;
    return DateTime.now().difference(lastActiveAt!) <
        const Duration(minutes: 5);
  }
}

class ReportView {
  final int id;
  final String humanRef;
  final String type;
  final String status;
  final String body;
  final DateTime createdAt;
  final String? reportedAnimal;
  final String? reportedRoom;

  const ReportView({
    required this.id,
    required this.humanRef,
    required this.type,
    required this.status,
    required this.body,
    required this.createdAt,
    this.reportedAnimal,
    this.reportedRoom,
  });

  factory ReportView.fromJson(Map<String, dynamic> j) => ReportView(
    id: (j['id'] as num).toInt(),
    humanRef: j['human_ref'] as String? ?? '',
    type: j['type'] as String? ?? '',
    status: j['status'] as String? ?? '',
    body: j['body'] as String? ?? '',
    createdAt: DateTime.parse(j['created_at'] as String).toLocal(),
    reportedAnimal: j['reported_animal'] as String?,
    reportedRoom: j['reported_room'] as String?,
  );
}

class SupportConversation {
  final String conversationId;
  final String partnerId;
  final String? partnerDisplayId;
  final String? partnerAnimal;
  final int unreadCount;
  final DateTime? lastMessageAt;

  const SupportConversation({
    required this.conversationId,
    required this.partnerId,
    this.partnerDisplayId,
    this.partnerAnimal,
    this.unreadCount = 0,
    this.lastMessageAt,
  });

  factory SupportConversation.fromJson(Map<String, dynamic> j) =>
      SupportConversation(
        conversationId: j['conversation_id'] as String,
        partnerId: j['partner_id'] as String,
        partnerDisplayId: j['partner_display_id'] as String?,
        partnerAnimal: j['partner_animal'] as String?,
        unreadCount: (j['unread_count'] as num?)?.toInt() ?? 0,
        lastMessageAt: j['last_message_at'] != null
            ? DateTime.parse(j['last_message_at'] as String).toLocal()
            : null,
      );

  String get displayName => partnerDisplayId ?? partnerAnimal ?? 'Unknown';
}

class AuditRow {
  final int id;
  final String event;
  final Map<String, dynamic> details;
  final DateTime createdAt;

  const AuditRow({
    required this.id,
    required this.event,
    required this.details,
    required this.createdAt,
  });

  factory AuditRow.fromJson(Map<String, dynamic> j) => AuditRow(
    id: (j['id'] as num).toInt(),
    event: j['event'] as String? ?? '',
    details: Map<String, dynamic>.from(j['details'] as Map? ?? {}),
    createdAt: DateTime.parse(j['created_at'] as String).toLocal(),
  );
}
