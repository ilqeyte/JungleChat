import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/safe_errors.dart';
import '../../core/theme.dart';
import '../../services/feedback_service.dart';
import '../../services/group_service.dart';
import '../../services/realtime_chat.dart';
import '../chats/message_actions.dart';
import '../home/home_tab.dart';
import '../chats/chats_tab.dart' show readReceiptTick;
import '../settings/auto_delete_timer_dialog.dart';

/// Real-time group chat screen.
class GroupChatScreen extends ConsumerStatefulWidget {
  final String groupId;
  final String? groupName;

  const GroupChatScreen({super.key, required this.groupId, this.groupName});

  @override
  ConsumerState<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends ConsumerState<GroupChatScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final _focusNode = FocusNode();
  StreamSubscription<List<GroupMessage>>? _sub;
  List<GroupMessage> _messages = [];
  // Optimistic sends: shown instantly keyed by the stable client_msg_id
  // (B9); reconciled when the confirmed stream row arrives (by id, or by
  // client_msg_id if realtime beat the RPC response). No content matching.
  final Map<String, GroupMessage> _pending = {};
  // Newest confirmed row already seen — gates mark-read and auto-scroll so
  // edits/deletes/reaction events don't fire RPCs or yank the scroll.
  String? _lastNewestId;
  Map<String, String> _memberNames = {}; // userId -> displayAnimalId
  bool _loading = true;
  bool _sending = false;
  String? _error;
  String _title = '';
  // Edit mode: id of my message being edited (30-min window enforced
  // server-side; the composer shows a banner while editing).
  String? _editingId;
  // Reply mode: the message being replied to (composer banner + quoted
  // preview attached on send).
  GroupMessage? _replyTo;
  // Live reactions: key '<message_id>|<user_id>' -> emoji.
  Map<String, String> _reactions = {};
  // Bucketed per-message reactions: rebuilt once per build() (was: rebuilt
  // implicitly by walking the flat map inside every bubble's build). See
  // bucketReactionsByMessage in message_actions.dart.
  Map<String, Map<String, String>> _reactionsByMessage = const {};
  StreamSubscription<Map<String, String>>? _reactSub;
  // Captured once so the dispose-time markRead can still bump the Chats-tab
  // badge AFTER this screen is gone (ref of a disposed State throws).
  late final _readTick = ref.read(readReceiptTick.notifier);

  @override
  void initState() {
    super.initState();
    _title = widget.groupName ?? 'Group';
    currentOpenGroupId.value = widget.groupId;
    // WHY: opening a group chat must clear the unread badge immediately —
    // previously markRead only fired on a new foreign row from the stream
    // and on dispose, so a notification-driven open left the badge stuck
    // until the user left the screen. Mirrors the DM flow.
    GroupService().markRead(widget.groupId).then((_) {
      _readTick.state++;
    }).catchError((_) {});
    _loadMembers();
    _subscribe();
    _subscribeReactions();
    _subscribeBroadcast();
  }

  @override
  void dispose() {
    if (currentOpenGroupId.value == widget.groupId) {
      currentOpenGroupId.value = null;
    }
    _sub?.cancel();
    _reactSub?.cancel();
    // Tear down the grp:{id} broadcast channel (message fast-path) so the
    // singleton does not leak channels for closed threads.
    RealtimeChat().closeGroup(widget.groupId);
    // Leaving the chat: final read-mark so the badge always clears.
    GroupService()
        .markRead(widget.groupId)
        .then((_) {
          _readTick.state++;
        })
        .catchError((_) {});
    _controller.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _loadMembers() async {
    try {
      final info = await GroupService().getGroupInfo(widget.groupId);
      if (!mounted) return;
      final names = <String, String>{};
      for (final m in info.members) {
        names[m.userId] = m.displayAnimalId;
      }
      if (!mounted) return;
      setState(() {
        _memberNames = names;
        _title = info.name;
      });
    } catch (e) {
      // Non-critical — just show "Group" as title
    }
  }

  void _subscribeReactions() {
    _reactSub = GroupService().reactions(widget.groupId).listen((map) {
      if (!mounted) return;
      setState(() => _reactions = map);
    });
  }

  /// Phase 5.1: Realtime Broadcast fast-path for group messages. Registered
  /// ONCE (NOT inside [_subscribe]'s retry path) so a RETRY-button press never
  /// stacks a second listener on the same channel. The postgres_changes stream
  /// ([GroupService.messages]) is the authoritative reconciliation + mark-read
  /// trigger; a broadcast arrives <100ms and is deduped by id when postgres
  /// confirms. Cleanup is via [closeGroup] in [dispose], which removes the
  /// whole `grp:{groupId}` channel (and every listener on it) from the
  /// singleton so closed threads don't leak channels.
  void _subscribeBroadcast() {
    RealtimeChat().onGroupMessage(widget.groupId, (payload) {
      if (!mounted) return;
      final m = GroupMessage.fromJson(Map<String, dynamic>.from(payload));
      setState(() {
        // Dedup by id — postgres_changes delivers the same committed row
        // moments later and re-sorts the whole list, so it never double-renders.
        if (!_messages.any((x) => x.id == m.id)) {
          _messages = [m, ..._messages]
            ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
        }
      });
    });
  }

  void _subscribe() {
    // Retry after an error must not stack a second realtime channel on top
    // of the first one (duplicate markReads, duplicate setStates).
    _sub?.cancel();
    _sub = GroupService()
        .messages(widget.groupId)
        .listen(
          (msgs) {
            if (!mounted) return;
            final myId =
                Supabase.instance.client.auth.currentUser?.id ?? '';
            final newestId = msgs.isEmpty ? null : msgs.first.id;
            final isNewRow = newestId != null && newestId != _lastNewestId;
            final firstLoad = _lastNewestId == null && newestId != null;
            setState(() {
              _messages = msgs;
              _loading = false;
              // Retire pending bubbles: exact-id match, or the just-sent row
              // that arrived via realtime before the RPC response (matched by
              // its client_msg_id). No content matching (B9).
              if (_pending.isNotEmpty) {
                final ids = msgs.map((m) => m.id).toSet();
                final clientIds = msgs
                    .map((m) => m.clientMsgId)
                    .whereType<String>()
                    .toSet();
                _pending.removeWhere((k, m) {
                  if (ids.contains(k)) return true;
                  if (clientIds.contains(k)) return true;
                  return false;
                });
              }
            });
            _lastNewestId = newestId;
            // Mark read ONCE per actually-new row from someone else — not on
            // every stream event (my own edits/deletes/reactions used to
            // fire mark_group_read + a full Chats-tab reload each time).
            if (isNewRow &&
                msgs.isNotEmpty &&
                msgs.first.senderId != myId) {
              GroupService()
                  .markRead(widget.groupId)
                  .then((_) {
                    _readTick.state++;
                  })
                  .catchError((_) {});
            }
            // Auto-scroll only on genuinely new rows: initial load always
            // lands at the bottom; afterwards only when I sent the message
            // or was already reading near the bottom. A user scrolled up in
            // history is no longer yanked down by an unrelated event.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!_scrollController.hasClients) return;
              if (firstLoad) {
                _scrollController.jumpTo(0);
                return;
              }
              if (!isNewRow) return;
              final mine = msgs.isNotEmpty && msgs.first.senderId == myId;
              final nearBottom = _scrollController.offset < 300;
              if (mine || nearBottom) _scrollController.jumpTo(0);
            });
          },
          onError: (e) {
            if (!mounted) return;
            setState(() {
              _loading = false;
              _error = SafeErrors.message(e);
            });
          },
        );
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;

    // EDIT flow: update the existing row — the realtime stream re-renders
    // it with the "edited" mark.
    if (_editingId != null) {
      final id = _editingId!;
      setState(() => _sending = true);
      try {
        await GroupService().editGroupMessage(id, text);
        if (!mounted) return;
        setState(() => _editingId = null);
        _controller.clear();
        FeedbackService.messageSent();
      } catch (e) {
        if (!mounted) return;
        FeedbackService.failure();
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(SafeErrors.message(e))));
      } finally {
        if (mounted) setState(() => _sending = false);
      }
      return;
    }

    setState(() => _sending = true);
    _controller.clear();
    final replyId = _replyTo?.id;
    if (mounted) setState(() => _replyTo = null);

    // Optimistic: the bubble appears NOW, keyed by the stable client_msg_id
    // the server will echo back (B9). No content-matching — the bubble is
    // retired by client_msg_id when the realtime row arrives.
    final clientMsgId = GroupService().newClientMsgId();
    final tempId = clientMsgId;
    final myId = Supabase.instance.client.auth.currentUser?.id ?? '';
    final optimistic = GroupMessage(
      id: tempId,
      senderId: myId,
      content: text,
      createdAt: DateTime.now(),
      isMine: true,
      replyToId: replyId,
      clientMsgId: clientMsgId,
    );
    setState(() {
      _pending[tempId] = optimistic;
    });

    try {
      final id = await GroupService().sendGroupMessage(
        widget.groupId,
        text,
        replyTo: replyId,
        clientMsgId: clientMsgId,
      );
      // Re-key the pending bubble to the real id; the stream row replaces it.
      if (mounted) {
        setState(() {
          final pending = _pending.remove(tempId);
          if (pending != null) _pending[id] = pending;
        });
      }
      // Fast path: tell other members immediately. postgres_changes confirms
      // the same committed row and dedups by id, so it never double-renders.
      RealtimeChat().broadcastGroupMessage(
        widget.groupId,
        {
          'id': id,
          'sender_id': myId,
          'content': text,
          'created_at': DateTime.now().toUtc().toIso8601String(),
          'reply_to_id': replyId,
          'client_msg_id': clientMsgId,
        },
      );
      FeedbackService.messageSent();
    } catch (e) {
      if (!mounted) return;
      // Remove the bubble and give the text back to the input.
      setState(() => _pending.remove(tempId));
      _controller.text = text; // Restore on failure
      if (replyId != null && mounted) {
        final original = _messages.where((m) => m.id == replyId).toList();
        if (original.isNotEmpty) setState(() => _replyTo = original.first);
      }
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(SafeErrors.message(e))));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// Toggle my reaction on a message (WhatsApp model).
  ///
  /// Tapping the emoji I already have CLEARS it. Both reaction RPCs treat an
  /// empty p_emoji as a delete (0038_community_reply_reactions.sql), but the
  /// client only ever sent a non-empty emoji — so reactions could be added and
  /// switched but never removed.
  Future<void> _react(GroupMessage m, String emoji) async {
    final myId = Supabase.instance.client.auth.currentUser?.id ?? '';
    final mine = _reactions['${m.id}|$myId'] ?? '';
    final next = mine == emoji ? '' : emoji;
    try {
      await GroupService().reactGroupMessage(m.id, next);
      if (!mounted) return;
      FeedbackService.tap();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(SafeErrors.message(e))));
    }
  }

  void _startReply(GroupMessage m) {
    setState(() {
      _editingId = null;
      _replyTo = m;
    });
    _focusNode.requestFocus();
  }

  // ── Message actions (long-press): reactions / reply / copy / edit / delete ──

  void _messageMenu(GroupMessage m, bool mine) {
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
                  setState(() {
                    _editingId = m.id;
                    _controller.text = m.content;
                  });
                }),
              ),
            if (mine && !m.isDeleted)
              ListTile(
                leading: const Icon(
                  Icons.delete_outline,
                  color: JCColors.danger,
                ),
                title: Text(
                  'Delete',
                  style: TextStyle(color: JCColors.danger),
                ),
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

  Future<void> _confirmDelete(GroupMessage m) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dlgCtx) => AlertDialog(
        backgroundColor: JCColors.surface,
        title: Text('Delete message?', style: JCTypography.title),
        content: Text(
          'It will be deleted for everyone in the group.',
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
      await GroupService().deleteGroupMessage(m.id);
      if (!mounted) return;
      FeedbackService.tap();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(SafeErrors.message(e))));
    }
  }

  static Duration? _parseInterval(String? interval) {
    if (interval == null) return null;
    if (interval.contains('days')) {
      final days = int.tryParse(interval.split(' ').first);
      if (days != null) return Duration(days: days);
    }
    if (interval.contains('hours') || interval.contains(':')) {
      final parts = interval.split(':');
      if (parts.length >= 2) {
        final hours = int.tryParse(parts[0]);
        if (hours != null) return Duration(hours: hours);
      }
      final hours = int.tryParse(interval.replaceAll('hours', '').trim());
      if (hours != null) return Duration(hours: hours);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final myId = Supabase.instance.client.auth.currentUser?.id ?? '';
    // Confirmed + optimistic, newest first (index 0 renders at the bottom).
    final msgs = [..._messages, ..._pending.values]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    // Bucket the reactions once per build() — see message_actions.dart.
    // The bucket map is what the item builder reads; computing it here
    // (rather than per-bubble) keeps reaction churn from doing an O(N×M)
    // scan on every scroll frame.
    _reactionsByMessage = bucketReactionsByMessage(_reactions);

    return Scaffold(
      backgroundColor: JCColors.background,
      appBar: AppBar(
        backgroundColor: JCColors.surface,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: FeedbackService.click(() => context.pop()),
        ),
        title: GestureDetector(
          onTap: FeedbackService.click(
            () => context.push(
              '/group-info/${widget.groupId}',
              extra: {'name': _title},
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_title, style: JCTypography.title.copyWith(fontSize: 17)),
              if (_memberNames.isNotEmpty)
                Text(
                  '${_memberNames.length} members',
                  style: JCTypography.secondary.copyWith(fontSize: 12),
                ),
            ],
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.timer_outlined, size: 22),
            onPressed: FeedbackService.click(() async {
              if (!mounted) return;
              final messenger = ScaffoldMessenger.of(context);
              try {
                final current = await GroupService().getGroupAutoDelete(
                  widget.groupId,
                );
                final duration = _parseInterval(current);
                final initial = AutoDeleteOption.fromDuration(duration);
                if (!mounted) return;
                await showAutoDeleteTimerDialog(
                  // ignore: use_build_context_synchronously
                  context,
                  groupId: widget.groupId,
                  title: 'Auto-Delete Timer',
                  initialValue: initial,
                );
              } catch (e) {
                if (!mounted) return;
                messenger.showSnackBar(
                  SnackBar(content: Text(SafeErrors.message(e))),
                );
              }
            }),
          ),
          IconButton(
            icon: const Icon(Icons.info_outline_rounded, size: 22),
            onPressed: FeedbackService.click(
              () => context.push(
                '/group-info/${widget.groupId}',
                extra: {'name': _title},
              ),
            ),
          ),
        ],
      ),
      // WHY: the DM screen wraps its body in SafeArea; without it the
      // group composer / message list can be clipped by the system gesture
      // bar on edge-to-edge devices.
      body: SafeArea(child: Column(
        children: [
          // Messages
          Expanded(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: JCColors.accent,
                    ),
                  )
                : _error != null
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _error!,
                          style: JCTypography.secondary,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton(
                          onPressed: FeedbackService.click(() {
                            setState(() {
                              _loading = true;
                              _error = null;
                            });
                            _subscribe();
                          }),
                          child: const Text('RETRY'),
                        ),
                      ],
                    ),
                  )
                : msgs.isEmpty
                ? Center(
                    child: Text(
                      'No messages yet.\nSay hello!',
                      textAlign: TextAlign.center,
                      style: JCTypography.secondary,
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    reverse: true,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    // Cache two screens above + below the viewport so
                    // scrolling stays at native frame rate on long histories.
                    // ignore: deprecated_member_use
                    cacheExtent: 800,
                    itemCount: msgs.length,
                    itemBuilder: (context, index) {
                      final msg = msgs[index];
                      final isMine = msg.senderId == myId;
                      final showHeader =
                          index == msgs.length - 1 ||
                          msgs[index + 1].senderId != msg.senderId;
                      final senderName = _memberNames[msg.senderId] ?? '???';
                      // Quoted reply preview: look the original up among the
                      // loaded messages; missing originals render a fallback.
                      GroupMessage? original;
                      if (msg.replyToId != null) {
                        for (final m in msgs) {
                          if (m.id == msg.replyToId) {
                            original = m;
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
                          : (original.senderId == myId
                                ? 'You'
                                : (_memberNames[original.senderId] ?? '???'));
                      // Pre-bucketed per-message reactions: O(1) lookup by
                      // message id instead of an O(messages × reactions) map
                      // scan on every scroll frame.
                      final scopedReactions =
                          _reactionsByMessage[msg.id] ?? const {};
                      final bubble = _MessageBubble(
                        message: msg,
                        isMine: isMine,
                        senderName: senderName,
                        showHeader: showHeader,
                        // Quoted reply preview above the bubble.
                        quotedText: quoted,
                        quotedBy: quotedBy,
                        quotedMine: original?.senderId == myId,
                        // Live reaction chips under the bubble.
                        reactionChips: aggregateReactionsForMessage(
                          messageReactions: scopedReactions,
                          myId: myId,
                        ),
                        onReactionTap: (emoji) => _react(msg, emoji),
                        // Tap the sender's name to open their profile.
                        onSenderTap: senderName == '???'
                            ? null
                            : FeedbackService.click(
                                () => context.push(
                                  '/profile/${msg.senderId}',
                                  extra: {'displayId': senderName},
                                ),
                              ),
                        // Long-press: reactions / reply / copy / edit / delete.
                        onLongPress: _pending.containsKey(msg.id)
                            ? null
                            : FeedbackService.click(
                                () => _messageMenu(msg, isMine),
                              ),
                        // Swipe right to reply.
                        onSwipeReply: _pending.containsKey(msg.id) || msg.isDeleted
                            ? null
                            : () => _startReply(msg),
                      );
                      // RepaintBoundary isolates each bubble's paint so
                      // scrolling + reaction updates don't drag the whole
                      // list through the rasterizer.
                      return RepaintBoundary(
                        key: ValueKey<String>('gm-${msg.id}'),
                        child: bubble,
                      );
                    },
                  ),
          ),

          // Input
          Container(
            padding: EdgeInsets.fromLTRB(
              12,
              8,
              12,
              MediaQuery.of(context).padding.bottom + 8,
            ),
            decoration: const BoxDecoration(
              color: JCColors.surface,
              border: Border(top: BorderSide(color: JCColors.outline)),
            ),
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
                      border: Border(
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
                                _replyTo!.senderId ==
                                        Supabase
                                            .instance
                                            .client
                                            .auth
                                            .currentUser
                                            ?.id
                                    ? 'Replying to you'
                                    : 'Replying to ${_memberNames[_replyTo!.senderId] ?? '???'}',
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
                          onTap: FeedbackService.click(() {
                            setState(() => _editingId = null);
                            _controller.clear();
                          }),
                          child: const Icon(
                            Icons.close_rounded,
                            size: 16,
                            color: JCColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        focusNode: _focusNode,
                        maxLength: 1000,
                        minLines: 1,
                        maxLines: 4,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) {
                          FeedbackService.tap();
                          _send();
                        },
                        style: JCTypography.body,
                        decoration: InputDecoration(
                          counterText: '',
                          hintText: _editingId != null
                              ? 'Edit your message'
                              : 'Write a message',
                          border: InputBorder.none,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: _sending
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: JCColors.accent,
                              ),
                            )
                          : const Icon(
                              Icons.send_rounded,
                              color: JCColors.accent,
                            ),
                      onPressed: _sending ? null : FeedbackService.click(_send),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final GroupMessage message;
  final bool isMine;
  final String senderName;
  final bool showHeader;
  final VoidCallback? onSenderTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onSwipeReply;
  final String? quotedText;
  final String? quotedBy;
  final bool quotedMine;
  final List<ReactionChipData> reactionChips;
  final ValueChanged<String> onReactionTap;

  const _MessageBubble({
    required this.message,
    required this.isMine,
    required this.senderName,
    required this.showHeader,
    required this.reactionChips,
    required this.onReactionTap,
    this.onSenderTap,
    this.onLongPress,
    this.onSwipeReply,
    this.quotedText,
    this.quotedBy,
    this.quotedMine = false,
  });

  @override
  Widget build(BuildContext context) {
    final bubble = Container(
      margin: EdgeInsets.only(
        top: showHeader ? 12 : 2,
        left: isMine ? 48 : 0,
        right: isMine ? 0 : 48,
      ),
      child: Column(
        crossAxisAlignment: isMine
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          if (showHeader && !isMine)
            Padding(
              padding: const EdgeInsets.only(bottom: 4, left: 4),
              child: InkWell(
                onTap: onSenderTap,
                borderRadius: BorderRadius.circular(4),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 2,
                    vertical: 1,
                  ),
                  child: Text(
                    senderName,
                    style: JCTypography.secondary.copyWith(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          if (quotedText != null)
            // Quoted reply preview: accent bar + author + one-liner.
            Container(
              margin: EdgeInsets.only(
                bottom: 3,
                left: isMine ? 0 : 4,
                right: isMine ? 4 : 0,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              constraints: const BoxConstraints(maxWidth: 240),
              decoration: BoxDecoration(
                color: (quotedMine ? JCColors.accentDim : JCColors.surface)
                    .withValues(alpha: .65),
                borderRadius: BorderRadius.circular(8),
                border: Border(
                  left: BorderSide(
                    color: quotedMine ? JCColors.accent : JCColors.accent,
                    width: 3,
                  ),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
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
                    quotedText!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: JCTypography.secondary.copyWith(fontSize: 11),
                  ),
                ],
              ),
            ),
          if (message.isDeleted)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                gradient: isMine
                    ? JCColors.jungleGradientMine
                    : JCColors.jungleGradient,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                isMine ? 'You deleted this message' : 'Message deleted',
                style: JCTypography.secondary.copyWith(
                  fontStyle: FontStyle.italic,
                  fontSize: 13,
                ),
              ),
            )
          else
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                gradient: isMine
                    ? JCColors.jungleGradientMine
                    : JCColors.jungleGradient,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(isMine ? 16 : 4),
                  bottomRight: Radius.circular(isMine ? 4 : 16),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    message.content,
                    style: JCTypography.body.copyWith(fontSize: 15),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (message.editedAt != null) ...[
                        Text(
                          'edited',
                          style: JCTypography.secondary.copyWith(
                            fontSize: 9,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                        const SizedBox(width: 5),
                      ],
                      Text(
                        '${message.createdAt.hour.toString().padLeft(2, '0')}:${message.createdAt.minute.toString().padLeft(2, '0')}',
                        style: JCTypography.secondary.copyWith(fontSize: 10),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          // Reaction chips (live).
          if (reactionChips.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(left: isMine ? 0 : 4),
              child: ReactionChips(chips: reactionChips, onTap: onReactionTap),
            ),
        ],
      ),
    );

    // The long-press menu (reactions / reply / copy / edit / delete) MUST be
    // attached inside the swipe wrapper: wrapping SwipeToReply alone dropped
    // the long-press detector entirely, so long-pressing ANY normal group
    // message did nothing (no reactions, no menu) — DM screen nests the
    // detector inside the swipe wrapper and works.
    final content = onLongPress == null
        ? bubble
        : GestureDetector(onLongPress: onLongPress, child: bubble);
    if (onSwipeReply != null) {
      return Align(
        alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
        child: SwipeToReply(onReply: onSwipeReply!, child: content),
      );
    }
    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: content,
    );
  }
}
