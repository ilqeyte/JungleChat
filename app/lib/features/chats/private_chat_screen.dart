import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/config.dart';
import '../../core/auto_delete_interval.dart';
import '../../core/safe_errors.dart';
import '../../core/theme.dart';
import '../../services/admin_service.dart';
import '../../services/chat_service.dart';
import '../../services/realtime_chat.dart';
import '../../services/feedback_service.dart';
import '../home/home_tab.dart';
import 'chats_tab.dart' show readReceiptTick;
import '../reports/report_sheet.dart';
import '../settings/auto_delete_timer_dialog.dart';
import 'message_actions.dart';

/// Private chat (PRD Â§27). Newest at the bottom (reverse list). Sender
/// identity is stamped server-side on each row (streams cannot join).
class PrivateChatScreen extends ConsumerStatefulWidget {
  final String conversationId;

  const PrivateChatScreen({super.key, required this.conversationId});

  @override
  ConsumerState<PrivateChatScreen> createState() => _PrivateChatScreenState();
}

class _PrivateChatScreenState extends ConsumerState<PrivateChatScreen> {
  final _input = TextEditingController();
  late final ChatService _chat = ref.read(chatServiceProvider);
  String? _myId;
  String? _otherId;
  String? _otherDisplayId;
  String? _otherBio;
  bool _otherIsOnline = false;
  // Server-derived: the partner is the official admin ("Adam"). Verified
  // badge + logo avatar come from this flag, never from a hardcoded id.
  bool _isOfficial = false;

  // Speed + presence state.
  final Map<String, _PendingDm> _pending = {};
  Timer? _typingThrottle;
  // Surfaced as a ValueNotifier so only the small typing chip rebuilds when
  // the partner toggles typing — NOT the whole message list.
  final ValueNotifier<bool> _partnerTypingN = ValueNotifier<bool>(false);
  bool _typingAllowed = true;
  // Active auto-delete timer for THIS conversation, shown in the header
  // (Phase 6). Null/empty = off.
  String? _autoDeleteLabel;
  // Live message list (Phase 5.1 + 5.3): seeded from the in-memory history
  // cache for an instant open, then kept authoritative by the postgres_changes
  // stream, with the Realtime Broadcast channel as the low-latency fast path.
  // Both sources dedup by id, so a message is never double-rendered.
  List<DirectMessage> _messages = const [];
  StreamSubscription<List<DirectMessage>>? _msgSub;
  // Auto-clears the partner "typing…" chip after a burst of silence.
  Timer? _typingClear;
  // Edit mode: the id of the message being edited (30-min window enforced
  // server-side; the composer shows a banner while editing).
  String? _editingId;
  // Reply mode: the message being replied to (composer banner + quoted
  // preview attached on send).
  DirectMessage? _replyTo;
  /// Live reactions: key `<message_id>|<user_id>` -> emoji.
  Map<String, String> _reactions = {};
  StreamSubscription<Map<String, String>>? _reactSub;
  // True when the signed-in user is the admin: sends go through the audited
  // admin RPC and the admin-side read marker is also updated.
  bool _isAdmin = false;
  late final AdminService _admin = AdminService();
  // Riverpod notifier captured once: bumping the tick AFTER this screen is
  // disposed (dispose-time markRead) must not touch the dead widget's ref.
  late final _readTick = ref.read(readReceiptTick.notifier);
  // The newest confirmed message we already auto-marked read — prevents the
  // builder from re-firing mark_conversation_read on every unrelated rebuild.
  String? _lastAutoReadId;
  // Double-tap guard: two overlapping send RPCs would create two bubbles.
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _myId = Supabase.instance.client.auth.currentUser?.id;
    _loadOpen();
    _loadAutoDeleteLabel();
    _subscribeMessages();
    _subscribeTyping();
    _subscribeReactions();
    _subscribeTimerChanges();
    // Opening the chat marks it read (badge clears) and suppresses banner
    // noise for THIS conversation while it is open.
    _markRead();
    currentOpenConversationId.value = widget.conversationId;
  }

  void _subscribeReactions() {
    _reactSub = _chat.reactions(widget.conversationId).listen((map) {
      if (!mounted) return;
      setState(() => _reactions = map);
    });
  }

  /// Marks read on the user path, and additionally on the admin inbox when
  /// the current user is the admin. When the server confirms, the Chats tab
  /// is told to reload so the unread badge clears even with no new messages.
  void _markRead() {
    _chat
        .markRead(widget.conversationId)
        .then((_) {
          _readTick.state++;
        })
        .catchError((_) {});
    if (_isAdmin) {
      _admin.markSupportRead(widget.conversationId).catchError((_) {});
    }
  }

  /// Bug B8: collapse the 4 sequential round-trips that used to fire on every
  /// chat open (is_current_user_admin + is_official_conversation +
  /// list_conversations + get_my_profile) into ONE `open_conversation` RPC
  /// returning the partner identity, online state, official flag, my admin
  /// role, unread count, the partner's typing preference, and MY OWN typing
  /// preference. Also stamps the admin support-read while we know the role
  /// (this fixes a race where the old async _checkAdmin finished after
  /// _markRead ran).
  Future<void> _loadOpen() async {
    try {
      final v = await _chat.openConversation(widget.conversationId);
      if (v == null) return;
      if (!mounted) return;
      setState(() {
        _otherId = v.partnerId;
        _otherDisplayId = v.isOfficial ? 'Adam' : v.partnerDisplayId;
        _otherBio = v.partnerBio;
        _otherIsOnline = v.partnerIsOnline;
        _isOfficial = v.isOfficial;
        _isAdmin = v.amAdmin;
        _typingAllowed = v.myTypingEnabled;
      });
      if (_isAdmin) {
        _admin.markSupportRead(widget.conversationId).catchError((_) {});
      }
    } catch (_) {}
  }

  /// Phase 6: show the active disappearing-message timer in the header. The
  /// interval string comes straight from the server (RLS-enforced expiry); we
  /// only render the label, never decide what is expired.
  Future<void> _loadAutoDeleteLabel() async {
    try {
      final raw = await _chat.getConversationAutoDelete(widget.conversationId);
      if (!mounted) return;
      setState(() {
        _autoDeleteLabel = raw == null || raw == 'NULL' || raw.isEmpty
            ? null
            : humanizeInterval(raw);
      });
    } catch (_) {}
  }

  /// Bug B6: watch the partner's typing over the Realtime Broadcast channel
  /// instead of a Postgres Changes subscription on `conversations` — zero DB
  /// writes, zero RLS evaluation, no `conversations` row churn per keystroke.
  void _subscribeTyping() {
    RealtimeChat().onTypingConversation(widget.conversationId, () {
      if (!mounted) return;
      // A broadcast event means "typing now"; clear after 3s of silence.
      _partnerTypingN.value = true;
      _typingClear?.cancel();
      _typingClear = Timer(const Duration(seconds: 3), () {
        if (mounted) _partnerTypingN.value = false;
      });
    });
  }

  /// Phase 5.1 + 5.3: seed the list from the in-memory history cache for an
  /// instant open, then keep it authoritative via the postgres_changes stream
  /// (reconciliation fallback) and the Broadcast channel (fast path).
  void _subscribeMessages() {
    _chat
        .loadHistory(widget.conversationId)
        .then((hist) {
          if (!mounted) return;
          setState(() => _messages = hist);
        })
        .catchError((_) {});
    _msgSub = _chat.messages(widget.conversationId).listen((list) {
      if (!mounted) return;
      setState(() => _messages = list);
    });
    // Fast path: a freshly-sent row arrives here <100ms; postgres_changes
    // confirms it shortly after and dedups by id.
    RealtimeChat().onConversationMessage(widget.conversationId, (payload) {
      if (!mounted) return;
      final m = DirectMessage.fromJson(payload);
      setState(() {
        final idx = _messages.indexWhere((x) => x.id == m.id);
        if (idx >= 0) {
          _messages[idx] = m;
        } else {
          _messages.add(m);
        }
        _messages.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      });
    });
  }

  /// D2: a partner changing the auto-delete timer broadcasts a system notice
  /// so both sides see it immediately (the change applies to new messages
  /// only — stated in the dialog).
  void _subscribeTimerChanges() {
    RealtimeChat().onTimerChanged(widget.conversationId, (label) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            label.isEmpty
                ? 'Disappearing messages turned off'
                : 'Disappearing messages: $label',
          ),
        ),
      );
    });
  }

  void _onTextChanged(String text) {
    if (text.isEmpty) return;
    // Throttle: at most one broadcast per 1.5s while typing (B6 — no DB write).
    if (_typingThrottle?.isActive == true) return;
    _typingThrottle = Timer(const Duration(milliseconds: 1500), () {});
    RealtimeChat().sendTypingConversation(widget.conversationId);
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;

    // EDIT flow: update the existing row — no optimistic bubble, the
    // realtime stream re-renders it with the "edited" mark.
    if (_editingId != null) {
      final id = _editingId!;
      try {
        await _chat.editMessage(id, text);
        if (!mounted) return;
        setState(() => _editingId = null);
        _input.clear();
        FeedbackService.messageSent();
      } catch (e) {
        if (!mounted) return;
        FeedbackService.failure();
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(SafeErrors.message(e))));
      }
      return;
    }

    _input.clear();
    // Optimistic: the bubble appears NOW, keyed by the stable client_msg_id
    // the server will echo back (B9). No content-matching — the bubble is
    // retired by client_msg_id when the realtime row arrives.
    final clientMsgId = _chat.newClientMsgId();
    final tempId = clientMsgId;
    final replyId = _replyTo?.id;
    if (mounted) {
      setState(() {
        _pending[tempId] = _PendingDm(tempId, text);
        _replyTo = null;
      });
    }
    _sending = true;
    try {
      final id = _isAdmin
          ? await _admin.sendSupportMessage(
              widget.conversationId,
              text,
              replyTo: replyId,
              clientMsgId: clientMsgId,
            )
          : await _chat.send(
              widget.conversationId,
              text,
              replyTo: replyId,
              clientMsgId: clientMsgId,
            );
      // Fast path: tell the partner immediately. postgres_changes confirms the
      // same row and dedups by id, so it never double-renders.
      RealtimeChat().broadcastConversationMessage(
        widget.conversationId,
        {
          'id': id,
          'sender_id': _myId ?? '',
          'content': text,
          'created_at': DateTime.now().toUtc().toIso8601String(),
          'reply_to_id': replyId,
          'client_msg_id': clientMsgId,
          'expires_at': null,
        },
      );
      // Re-key the pending bubble to the real id; the stream row replaces it.
      if (mounted) {
        setState(() {
          final pending = _pending.remove(tempId);
          if (pending != null) _pending[id] = pending;
        });
      }
      FeedbackService.messageSent();
    } catch (e) {
      if (!mounted) return;
      // Remove the bubble and give the text back to the input.
      setState(() => _pending.remove(tempId));
      _input.text = text;
      FeedbackService.failure();
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(SafeErrors.message(e))));
    } finally {
      _sending = false;
    }
  }

  /// Toggle my reaction on a message (WhatsApp model).
  ///
  /// Tapping the emoji I already have CLEARS it. Both reaction RPCs treat an
  /// empty p_emoji as a delete (0038_community_reply_reactions.sql), but the
  /// client only ever sent a non-empty emoji — so reactions could be added and
  /// switched but never removed.
  Future<void> _react(DirectMessage m, String emoji) async {
    final mine = _reactions['${m.id}|$_myId'] ?? '';
    final next = mine == emoji ? '' : emoji;
    try {
      await _chat.react(m.id, next);
      if (!mounted) return;
      FeedbackService.tap();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(SafeErrors.message(e))));
    }
  }

  void _startReply(DirectMessage m) {
    setState(() {
      _editingId = null;
      _replyTo = m;
    });
  }

  // ── Message actions (long-press): reactions / reply / copy / edit / delete ──

  void _messageMenu(DirectMessage m) {
    final mine = m.senderId == _myId;
    final editable =
        mine &&
        !m.isDeleted &&
        m.createdAt.isAfter(
          DateTime.now().subtract(const Duration(minutes: 30)),
        );
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: JCColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!m.isDeleted)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    for (final e in kQuickReactions)
                      InkWell(
                        borderRadius: BorderRadius.circular(24),
                        onTap: FeedbackService.click(() {
                          Navigator.pop(sheetCtx);
                          _react(m, e);
                        }),
                        child: Padding(
                          padding: const EdgeInsets.all(6),
                          child: Text(e, style: const TextStyle(fontSize: 28)),
                        ),
                      ),
                    InkWell(
                      borderRadius: BorderRadius.circular(24),
                      onTap: FeedbackService.click(() async {
                        final emoji = await showReactionPicker(sheetCtx);
                        if (!sheetCtx.mounted) return;
                        Navigator.pop(sheetCtx);
                        if (emoji != null && emoji.isNotEmpty) _react(m, emoji);
                      }),
                      child: const Padding(
                        padding: EdgeInsets.all(10),
                        child: Icon(
                          Icons.add_rounded,
                          size: 24,
                          color: JCColors.accent,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (!m.isDeleted)
              ListTile(
                leading: const Icon(Icons.reply_rounded),
                title: const Text('Reply'),
                onTap: FeedbackService.click(() {
                  Navigator.pop(sheetCtx);
                  _startReply(m);
                }),
              ),
            if (!m.isDeleted)
              ListTile(
                leading: const Icon(Icons.copy_rounded),
                title: const Text('Copy'),
                onTap: FeedbackService.click(() {
                  Navigator.pop(sheetCtx);
                  copyMessage(context, m.content);
                }),
              ),
            if (editable)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Edit'),
                onTap: FeedbackService.click(() {
                  Navigator.pop(sheetCtx);
                  _startEdit(m);
                }),
              ),
            if (mine && !m.isDeleted)
              ListTile(
                leading: const Icon(
                  Icons.delete_outline,
                  color: JCColors.danger,
                ),
                title: Text('Delete', style: TextStyle(color: JCColors.danger)),
                onTap: FeedbackService.click(() {
                  Navigator.pop(sheetCtx);
                  _confirmDelete(m);
                }),
              ),
          ],
        ),
      ),
    );
  }

  void _startEdit(DirectMessage m) {
    setState(() {
      _editingId = m.id;
      _input.text = m.content;
    });
  }

  void _cancelEdit() {
    setState(() => _editingId = null);
    _input.clear();
  }

  Future<void> _confirmDelete(DirectMessage m) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dlgCtx) => AlertDialog(
        backgroundColor: JCColors.surface,
        title: Text('Delete message?', style: JCTypography.title),
        content: Text(
          'It will be deleted for everyone in this chat.',
          style: JCTypography.secondary,
        ),
        actions: [
          TextButton(
            onPressed: FeedbackService.click(
              () => Navigator.pop(dlgCtx, false),
            ),
            child: Text('CANCEL', style: JCTypography.secondary),
          ),
          TextButton(
            onPressed: FeedbackService.click(() => Navigator.pop(dlgCtx, true)),
            child: Text(
              'DELETE',
              style: JCTypography.secondary.copyWith(color: JCColors.danger),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _chat.deleteMessage(m.id);
      if (!mounted) return;
      FeedbackService.tap();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(SafeErrors.message(e))));
    }
  }

  void _actions() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: JCColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!_isOfficial) ...[
              ListTile(
                leading: const Icon(Icons.flag_outlined),
                title: const Text('Report this animal'),
                onTap: FeedbackService.click(() async {
                  Navigator.pop(context);
                  showReportSheet(
                    context,
                    ref,
                    type: 'user_report',
                    targetUser: _otherId,
                    contextLine: _otherDisplayId ?? '',
                  );
                }),
              ),
              ListTile(
                leading: const Icon(Icons.block_outlined),
                title: const Text('Block this animal'),
                onTap: FeedbackService.click(() async {
                  Navigator.pop(context);
                  try {
                    final row = await Supabase.instance.client
                        .from('conversations')
                        .select('user_a, user_b')
                        .eq('id', widget.conversationId)
                        .single();
                    final other = (row['user_a'] == _myId)
                        ? row['user_b']
                        : row['user_a'];
                    await Supabase.instance.client.rpc(
                      'block_animal',
                      params: {'p_target': other},
                    );
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Animal blocked.')),
                    );
                    if (context.mounted) Navigator.pop(context);
                  } catch (e) {
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(SafeErrors.message(e))),
                    );
                  }
                }),
              ),
            ],
            ListTile(
              leading: const Icon(Icons.delete_outline, color: JCColors.danger),
              title: const Text('Delete conversation'),
              onTap: FeedbackService.click(() async {
                Navigator.pop(context);
                try {
                  await _chat.deleteConversation(widget.conversationId);
                  if (!mounted) return;
                  Navigator.pop(context);
                } catch (e) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(SafeErrors.message(e))),
                  );
                }
              }),
            ),
            ListTile(
              leading: const Icon(Icons.timer_outlined),
              title: const Text('Auto-Delete Timer'),
              onTap: FeedbackService.click(() async {
                Navigator.pop(context);
                try {
                  final current = await _chat.getConversationAutoDelete(
                    widget.conversationId,
                  );
                  final duration = _parseInterval(current);
                  final initial = AutoDeleteOption.fromDuration(duration);
                  if (!mounted) return;
                  await showAutoDeleteTimerDialog(
                    context,
                    conversationId: widget.conversationId,
                    title: 'Auto-Delete Timer',
                    initialValue: initial,
                  );
                  // D2: surface a system notice to the partner (both sides see
                  // it immediately). The change applies to new messages only.
                  try {
                    final raw = await _chat.getConversationAutoDelete(
                      widget.conversationId,
                    );
                    final label = raw == null || raw == 'NULL' || raw.isEmpty
                        ? ''
                        : humanizeInterval(raw);
                    if (!mounted) return;
                    setState(
                      () => _autoDeleteLabel = label.isEmpty ? null : label,
                    );
                    RealtimeChat().broadcastTimerChanged(
                      widget.conversationId,
                      label,
                    );
                  } catch (_) {}
                } catch (e) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(SafeErrors.message(e))),
                  );
                }
              }),
            ),
          ],
        ),
      ),
    );
  }

  /// Bottom sheet on tapping the partner's name/avatar: profile + the
  /// WhatsApp-style chat actions (report / block / delete conversation).
  Future<void> _openPartnerSheet() async {
    final known = <String>{};
    if (_otherId != null && _otherId!.isNotEmpty) {
      try {
        final blocks = await ref.read(socialServiceProvider).myBlocks();
        known.addAll(blocks.map((b) => b.id));
      } catch (_) {}
    }
    if (!mounted) return;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: JCColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_otherId != null && _otherId!.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: const Text('View profile'),
                onTap: FeedbackService.click(() {
                  Navigator.pop(context);
                  context.push(
                    '/profile/$_otherId',
                    extra: {'displayId': _otherDisplayId},
                  );
                }),
              ),
            ListTile(
              leading: const Icon(Icons.flag_outlined),
              title: const Text('Report this animal'),
              onTap: FeedbackService.click(() {
                Navigator.pop(context);
                showReportSheet(
                  context,
                  ref,
                  type: 'user_report',
                  targetUser: _otherId,
                  contextLine: _otherDisplayId ?? '',
                );
              }),
            ),
            if (_otherId != null && _otherId!.isNotEmpty)
              ListTile(
                leading: Icon(
                  known.contains(_otherId)
                      ? Icons.lock_open_rounded
                      : Icons.block_outlined,
                ),
                title: Text(
                  known.contains(_otherId)
                      ? 'Unblock this animal'
                      : 'Block this animal',
                ),
                onTap: FeedbackService.click(() async {
                  final unblock = known.contains(_otherId);
                  Navigator.pop(context);
                  await _blockPartner(unblock: unblock);
                }),
              ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: JCColors.danger),
              title: const Text(
                'Delete conversation',
                style: TextStyle(color: JCColors.danger),
              ),
              onTap: FeedbackService.click(() {
                Navigator.pop(context);
                _confirmDeleteConversation();
              }),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _blockPartner({required bool unblock}) async {
    final other = _otherId;
    if (other == null || other.isEmpty) return;
    try {
      final social = ref.read(socialServiceProvider);
      if (unblock) {
        await social.unblock(other);
      } else {
        await social.block(other);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(unblock ? 'Animal unblocked.' : 'Animal blocked.'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(SafeErrors.message(e))));
    }
  }

  Future<void> _confirmDeleteConversation() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete conversation?'),
        content: const Text(
          'All messages in this conversation will be deleted '
          'for both animals.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: JCColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await _chat.deleteConversation(widget.conversationId);
      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(SafeErrors.message(e))));
    }
  }

  // Helper to parse PostgreSQL interval string to Duration
  static Duration? _parseInterval(String? interval) {
    if (interval == null) return null;
    // Parse PostgreSQL interval format like "24:00:00" for 24 hours, "7 days" etc.
    // PostgreSQL interval format can vary, but typically it's like "24:00:00" for hours
    // or "7 days" for days. We'll handle common formats.
    if (interval.contains('days')) {
      final days = int.tryParse(interval.split(' ').first);
      if (days != null) return Duration(days: days);
    }
    if (interval.contains('hours') || interval.contains(':')) {
      // Try to parse as HH:MM:SS
      final parts = interval.split(':');
      if (parts.length >= 2) {
        final hours = int.tryParse(parts[0]);
        if (hours != null) return Duration(hours: hours);
      }
      // Try just hours
      final hours = int.tryParse(interval.replaceAll('hours', '').trim());
      if (hours != null) return Duration(hours: hours);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _isOfficial
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircleAvatar(
                    radius: 14,
                    backgroundColor: JCColors.accentDim,
                    child: const Icon(
                      Icons.support_agent_rounded,
                      size: 18,
                      color: JCColors.accent,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'ADAM',
                    style: JCTypography.animalId.copyWith(fontSize: 16),
                  ),
                  const SizedBox(width: 4),
                  const Icon(
                    Icons.verified_rounded,
                    size: 18,
                    color: JCColors.accent,
                  ),
                ],
              )
            : GestureDetector(
                behavior: HitTestBehavior.opaque,
                // Tap the partner's name/avatar: profile + chat actions
                // (report / block / delete) in one sheet.
                onTap: FeedbackService.click(_openPartnerSheet),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 10,
                  ),
                  child: Text(
                    (_otherDisplayId ?? '').toUpperCase(),
                    style: JCTypography.animalId.copyWith(fontSize: 16),
                  ),
                ),
              ),
        bottom: _otherBio == null && !_otherIsOnline
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(20),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Column(
                    children: [
                      if (_otherIsOnline)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 7,
                              height: 7,
                              decoration: const BoxDecoration(
                                color: JCColors.onlineGreen,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 5),
                            Text(
                              'online',
                              style: JCTypography.secondary.copyWith(
                                fontSize: 11,
                                color: JCColors.onlineGreen,
                              ),
                            ),
                          ],
                        ),
                      if (_otherBio != null && _otherBio!.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            _otherBio!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: JCTypography.secondary.copyWith(
                              fontSize: 11,
                            ),
                          ),
                        ),
                      if (_autoDeleteLabel != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.timer_outlined,
                                size: 12,
                                color: JCColors.textSecondary,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                _autoDeleteLabel!,
                                style: JCTypography.secondary.copyWith(
                                  fontSize: 11,
                                  color: JCColors.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
        actions: [
          IconButton(
            icon: const Icon(Icons.more_vert),
            onPressed: FeedbackService.click(_actions),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Typing indicator (partner) — wraps the chip in a ValueListenableBuilder
            // so typing churn does NOT rebuild the message list (only this
            // tiny row).
            ValueListenableBuilder<bool>(
              valueListenable: _partnerTypingN,
              builder: (_, typing, _) => typing && _typingAllowed
                  ? Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.only(left: 18, bottom: 4),
                        child: Text(
                          'typing…',
                          style: JCTypography.secondary.copyWith(
                            fontSize: 12,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            Expanded(
              child: Builder(
                builder: (_) {
                  // Authoritative + fast-path list (postgres_changes +
                  // broadcast, deduped by id). Seeded instantly from the
                  // in-memory history cache in _subscribeMessages.
                  final confirmed = _messages;
                  if (_pending.isNotEmpty) {
                    final ids = confirmed.map((m) => m.id).toSet();
                    final clientIds = confirmed
                        .map((m) => m.clientMsgId)
                        .whereType<String>()
                        .toSet();
                    _pending.removeWhere((k, p) {
                      // Real id arrived — stream owns this bubble now.
                      if (ids.contains(k)) return true;
                      // Realtime beat the RPC response: the just-sent row
                      // arrived while this bubble is still keyed by its
                      // client_msg_id. Retire it by client_msg_id (B9) — no
                      // content matching, so the same text twice never
                      // double-renders or drops a bubble.
                      if (clientIds.contains(k)) return true;
                      return false;
                    });
                  }
                  // Any NEW incoming message while the chat is open = read
                  // once per message, not once per rebuild (a reaction tap
                  // or reply toggle rebuilds the builder with the same
                  // newest message — re-firing mark_read here would spam
                  // the RPC and force a Chats-tab reload every time).
                  // WHY: must mark read regardless of sender. Opening a DM
                  // whose newest confirmed message is your own used to leave
                  // the unread badge stuck because the sender check blocked
                  // this branch (initState's _markRead ran once at mount, but
                  // the newest message can change between then and the first
                  // stream emission).
                  if (confirmed.isNotEmpty &&
                      confirmed.first.id != _lastAutoReadId) {
                    _lastAutoReadId = confirmed.first.id;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      _markRead();
                    });
                  }
                  // Merged view: confirmed (newest first) + optimistic pending.
                  final msgs = [
                    ...confirmed,
                    for (final p in _pending.values)
                      DirectMessage(
                        id: p.id,
                        senderId: _myId ?? '',
                        content: p.content,
                        createdAt: DateTime.now(),
                      ),
                  ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
                  if (msgs.isEmpty) {
                    return const Center(
                      child: Text(
                        'No messages yet. Say hello.',
                        style: JCTypography.secondary,
                      ),
                    );
                  }
                  // Bucket reactions ONCE per rebuild — previously the per-bubble
                  // aggregate walked the entire reactions map on every scroll
                  // frame, causing visible jank on long histories.
                  final byMessage = bucketReactionsByMessage(_reactions);
                  // Cache the screen width at build() time so item builders
                  // don't subscribe to MediaQuery (they would otherwise rebuild
                  // the whole list on every keyboard show / rotation).
                  final maxBubbleWidth =
                      MediaQuery.of(context).size.width * .78;
                  // Newest first (index 0) -> reversed list shows it at the
                  // bottom. Instant local echo: my unsent-lag is invisible
                  // because send() clears the field only after the server
                  // accepts, and the stream confirms within ~a second.
                  return ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.all(14),
                    // Cache two screens above + below the viewport so
                    // scrolling stays at native frame rate.
                    // ignore: deprecated_member_use
                    cacheExtent: 800,
                    itemCount: msgs.length,
                    itemBuilder: (_, i) {
                      final m = msgs[i];
                      final mine = m.senderId == _myId;
                      final time =
                          '${m.createdAt.hour.toString().padLeft(2, '0')}:${m.createdAt.minute.toString().padLeft(2, '0')}';

                      // Date chip when the day changes vs the next (older)
                      // message.
                      Widget? dateChip;
                      if (i == msgs.length - 1) {
                        dateChip = _dateChip(m.createdAt);
                      } else {
                        final older = msgs[i + 1];
                        if (!_sameDay(m.createdAt, older.createdAt)) {
                          dateChip = _dateChip(m.createdAt);
                        }
                      }

                      // Quoted reply preview: resolve among loaded messages.
                      DirectMessage? original;
                      if (m.replyToId != null) {
                        for (final o in msgs) {
                          if (o.id == m.replyToId) {
                            original = o;
                            break;
                          }
                        }
                      }
                      final quoted = original == null
                          ? null
                          : (original.isDeleted
                                ? 'Message deleted'
                                : original.content);
                      final quotedBy = original == null
                          ? null
                          : (original.senderId == _myId
                                ? 'You'
                                : (_isOfficial
                                      ? 'Adam'
                                      : (_otherDisplayId ?? '???')));

                      final Widget bubble;
                      if (m.isDeleted) {
                        bubble = Container(
                          margin: const EdgeInsets.only(bottom: 6),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          constraints: BoxConstraints(
                            maxWidth: maxBubbleWidth,
                          ),
                          decoration: BoxDecoration(
                            gradient: mine
                                ? JCColors.jungleGradientMine
                                : JCColors.jungleGradient,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: JCColors.outline),
                          ),
                          child: Text(
                            mine
                                ? 'You deleted this message'
                                : 'Message deleted',
                            style: JCTypography.secondary.copyWith(
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        );
                      } else {
                        bubble = Container(
                          margin: const EdgeInsets.only(bottom: 6),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          constraints: BoxConstraints(
                            maxWidth: maxBubbleWidth,
                          ),
                          decoration: BoxDecoration(
                            gradient: mine
                                ? JCColors.jungleGradientMine
                                : JCColors.jungleGradient,
                            borderRadius: BorderRadius.only(
                              topLeft: const Radius.circular(16),
                              topRight: const Radius.circular(16),
                              bottomLeft: Radius.circular(mine ? 16 : 4),
                              bottomRight: Radius.circular(mine ? 4 : 16),
                            ),
                            border: Border.all(color: JCColors.outline),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (quoted != null)
                                Container(
                                  margin: const EdgeInsets.only(bottom: 5),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: JCColors.surfaceHigh,
                                    borderRadius: BorderRadius.circular(8),
                                    border: const Border(
                                      left: BorderSide(
                                        color: JCColors.accent,
                                        width: 3,
                                      ),
                                    ),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        quotedBy ?? '',
                                        style: JCTypography.secondary.copyWith(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w700,
                                          color: JCColors.accent,
                                        ),
                                      ),
                                      Text(
                                        quoted,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: JCTypography.secondary.copyWith(
                                          fontSize: 11,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Flexible(
                                    child: Text(
                                      m.content,
                                      style: JCTypography.body,
                                    ),
                                  ),
                                  if (m.editedAt != null) ...[
                                    const SizedBox(width: 6),
                                    Text(
                                      'edited',
                                      style: JCTypography.secondary.copyWith(
                                        fontSize: 9,
                                        fontStyle: FontStyle.italic,
                                      ),
                                    ),
                                  ],
                                  const SizedBox(width: 8),
                                  // WhatsApp logic: subtle time inside the
                                  // bubble, bottom-right.
                                  Text(
                                    time,
                                    style: JCTypography.secondary.copyWith(
                                      fontSize: 10,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        );
                      }

                      // Pre-bucketed: lookup by message id is O(1) instead of
                      // a full map scan.
                      final chips = aggregateReactionsForMessage(
                        messageReactions: byMessage[m.id] ?? const {},
                        myId: _myId ?? '',
                      );

                      final wrapped = GestureDetector(
                        // Long-press: reactions / reply / copy / edit / delete.
                        onLongPress: _pending.containsKey(m.id)
                            ? null
                            : FeedbackService.click(() => _messageMenu(m)),
                        child: bubble,
                      );

                      // RepaintBoundary isolates each bubble's paint — the
                      // rasterizer can repaint one bubble without dragging
                      // its neighbors along. Critical for smooth scrolling
                      // on long histories with reactions / online dots.
                      final body = Column(
                        crossAxisAlignment: mine
                            ? CrossAxisAlignment.end
                            : CrossAxisAlignment.start,
                        children: [
                          if (dateChip != null)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: dateChip,
                            ),
                          if (chips.isNotEmpty)
                            ReactionChips(
                              chips: chips,
                              onTap: (emoji) => _react(m, emoji),
                            ),
                          Align(
                            alignment: mine
                                ? Alignment.centerRight
                                : Alignment.centerLeft,
                            child: _pending.containsKey(m.id) || m.isDeleted
                                ? wrapped
                                : SwipeToReply(
                                    onReply: () => _startReply(m),
                                    child: wrapped,
                                  ),
                          ),
                        ],
                      );

                      return RepaintBoundary(
                        // Stable key: keeps the element tree pinned across
                        // rebuilds so React-style reconciliation works and
                        // the ListView can recycle elements efficiently.
                        key: ValueKey<String>('dm-${m.id}'),
                        child: body,
                      );
                    },
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_replyTo != null)
                    Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: JCColors.accentDim.withValues(alpha: .3),
                        borderRadius: BorderRadius.circular(10),
                        border: const Border(
                          left: BorderSide(color: JCColors.accent, width: 3),
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.reply_rounded,
                            size: 14,
                            color: JCColors.accent,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  _replyTo!.senderId == _myId
                                      ? 'Replying to yourself'
                                      : (_isOfficial
                                            ? 'Replying to Adam'
                                            : 'Replying to ${_otherDisplayId ?? '???'}'),
                                  style: JCTypography.secondary.copyWith(
                                    fontSize: 11,
                                    color: JCColors.accent,
                                  ),
                                ),
                                Text(
                                  _replyTo!.isDeleted
                                      ? 'Message deleted'
                                      : _replyTo!.content,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: JCTypography.secondary.copyWith(
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          GestureDetector(
                            onTap: FeedbackService.click(
                              () => setState(() => _replyTo = null),
                            ),
                            child: const Icon(
                              Icons.close_rounded,
                              size: 16,
                              color: JCColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (_editingId != null)
                    Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: JCColors.accentDim.withValues(alpha: .4),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.edit_outlined,
                            size: 14,
                            color: JCColors.accent,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              'Editing message (30 min window)',
                              style: JCTypography.secondary.copyWith(
                                fontSize: 12,
                              ),
                            ),
                          ),
                          GestureDetector(
                            onTap: FeedbackService.click(_cancelEdit),
                            child: const Icon(
                              Icons.close_rounded,
                              size: 16,
                              color: JCColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  TextField(
                    controller: _input,
                    maxLength: AppConfig.maxMessageLength,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.send,
                    onChanged: _onTextChanged,
                    onSubmitted: (_) {
                      FeedbackService.tap();
                      _send();
                    },
                    decoration: InputDecoration(
                      counterText: '',
                      hintText: _editingId != null
                          ? 'Edit your message'
                          : 'Write a message',
                      suffixIcon: IconButton(
                        icon: const Icon(
                          Icons.send_rounded,
                          color: JCColors.accent,
                        ),
                        onPressed: FeedbackService.click(_send),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  Widget _dateChip(DateTime t) {
    final now = DateTime.now();
    final local = t.toLocal();
    String label;
    if (_sameDay(local, now)) {
      label = 'TODAY';
    } else if (_sameDay(local, now.subtract(const Duration(days: 1)))) {
      label = 'YESTERDAY';
    } else {
      label = '${local.day}/${local.month}/${local.year}';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: JCColors.surfaceHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(label, style: JCTypography.secondary.copyWith(fontSize: 11)),
    );
  }

  @override
  void dispose() {
    // Leaving the chat: final read-mark so the badge always clears.
    _markRead();
    if (currentOpenConversationId.value == widget.conversationId) {
      currentOpenConversationId.value = null;
    }
    _msgSub?.cancel();
    _typingClear?.cancel();
    // Tear down the dm:{id} broadcast channel (typing + messages + timer
    // notices) so the singleton does not leak channels for closed threads.
    RealtimeChat().closeConversation(widget.conversationId);
    _reactSub?.cancel();
    _typingThrottle?.cancel();
    _partnerTypingN.dispose();
    _input.dispose();
    super.dispose();
  }
}

class _PendingDm {
  final String id;
  final String content;

  const _PendingDm(this.id, this.content);
}
