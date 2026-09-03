import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/safe_errors.dart';
import '../../core/theme.dart';
import '../../services/chat_service.dart';
import '../../services/feedback_service.dart';
import '../../services/group_service.dart';
import '../../services/social_service.dart';
import '../home/home_tab.dart';
import '../../core/animal_glyph.dart';

/// Bumped by the chat screens the moment their mark-read RPC commits, so
/// this tab reloads and the unread badge clears even when no NEW message
/// arrived (reading alone triggers no realtime activity event).
final readReceiptTick = StateProvider<int>((ref) => 0);

/// Chats tab: talk requests, conversations, and groups.
class ChatsTab extends ConsumerStatefulWidget {
  const ChatsTab({super.key});

  @override
  ConsumerState<ChatsTab> createState() => _ChatsTabState();
}

class _ChatsTabState extends ConsumerState<ChatsTab> {
  List<TalkRequestView>? _incoming;
  List<ConversationView>? _conversations;
  List<GroupView>? _groups;
  Set<String> _official = {};
  // Official (Adam) threads never change status once known — cache the flag
  // per conversation so reloads don't fire one is_official_conversation RPC
  // per conversation (every realtime activity burst and read receipt used to
  // re-query the whole list).
  final Map<String, bool> _officialFlags = {};
  String? _error;
  bool _loading = true;
  StreamSubscription? _dmActivity;
  StreamSubscription? _gmActivity;
  Timer? _reloadDebounce;
  dynamic _tickSub;

  @override
  void initState() {
    super.initState();
    _load();
    _subscribeToActivity();
    // Reading a conversation/group clears its badge the moment the server
    // confirms the read receipt — no new message required.
    _tickSub = ref.listenManual(readReceiptTick, (_, _) => _debouncedReload());
  }

  /// Realtime: any new message in any of my conversations or groups
  /// re-loads the lists, so unread badges / "new message" rows update
  /// instantly — no refresh or reopening needed. Debounced lightly so a
  /// burst of messages triggers a single reload.
  void _subscribeToActivity() {
    final chat = ref.read(chatServiceProvider);
    _dmActivity = chat.conversationActivityStream().listen(
      (_) => _debouncedReload(),
    );
    _gmActivity = chat.groupMessageActivityStream().listen(
      (_) => _debouncedReload(),
    );
  }

  void _debouncedReload() {
    _reloadDebounce?.cancel();
    _reloadDebounce = Timer(
      const Duration(milliseconds: 500),
      () => _load(silent: true),
    );
  }

  @override
  void dispose() {
    _dmActivity?.cancel();
    _gmActivity?.cancel();
    _reloadDebounce?.cancel();
    _tickSub?.close();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent || _conversations == null) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      // One round-trip wall time: conversations, groups and requests load
      // in parallel instead of sequentially (slow networks feel it most).
      final results = await Future.wait([
        ref.read(chatServiceProvider).listConversations(),
        ref.read(groupServiceProvider).listMyGroups(),
        ref.read(socialServiceProvider).listRequests(incoming: true),
      ]);
      final conversations = results[0] as List<ConversationView>;
      final groups = results[1] as List<GroupView>;
      final incoming = results[2] as List<TalkRequestView>;
      // Official (Adam) threads: resolve ONLY unknown conversation ids —
      // known flags are cached, so steady-state reloads cost zero RPCs.
      final chat = ref.read(chatServiceProvider);
      final unknown = conversations
          .where((c) => !_officialFlags.containsKey(c.id))
          .toList();
      if (unknown.isNotEmpty) {
        final flags = await Future.wait(
          unknown.map((c) => chat.isOfficialConversation(c.id)).toList(),
        );
        for (var i = 0; i < unknown.length; i++) {
          _officialFlags[unknown[i].id] = flags[i];
        }
      }
      final official = conversations
          .where((c) => _officialFlags[c.id] == true)
          .map((c) => c.id)
          .toSet();
      if (!mounted) return;
      setState(() {
        _incoming = incoming;
        _conversations = conversations;
        _groups = groups;
        _official = official;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = SafeErrors.message(e);
      });
    }
  }

  Future<void> _respond(String id, bool accept) async {
    try {
      await ref.read(socialServiceProvider).respondRequest(id, accept);
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(SafeErrors.message(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      color: JCColors.accent,
      onRefresh: _load,
      child: CustomScrollView(
        // CustomScrollView + slivers means each section lazy-builds and
        // off-screen rows are NOT held in memory. Previously the entire
        // ListView with `children:` constructed every conversation tile
        // (avatar Stack + online dot + unread badge) up front; with a long
        // history this was a measurable jank source.
        key: const PageStorageKey<String>('chats-tab'),
        slivers: [
          const SliverPadding(
            padding: EdgeInsets.only(top: 12, bottom: 8),
          ),
          if (_loading)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Padding(
                padding: EdgeInsets.all(48),
                child: Center(
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: JCColors.accent,
                  ),
                ),
              ),
            )
          else ...[
            if (_error != null) ...[
              const SliverToBoxAdapter(child: SizedBox(height: 32)),
              SliverToBoxAdapter(
                child: Center(
                  child: Text(
                    'Could not load chats.\n$_error',
                    textAlign: TextAlign.center,
                    style: JCTypography.secondary,
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 12)),
              SliverToBoxAdapter(
                child: Center(
                  child: OutlinedButton(
                    onPressed: FeedbackService.click(_load),
                    child: const Text('RETRY'),
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 32)),
            ],

            // ---- Talk requests -----------------------------------------
            if (_incoming != null && _incoming!.isNotEmpty) ...[
              const SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                sliver: SliverToBoxAdapter(
                  child: Text(
                    'TALK REQUESTS',
                    style: TextStyle(
                      fontSize: 12,
                      letterSpacing: 2,
                      color: JCColors.textSecondary,
                    ),
                  ),
                ),
              ),
              const SliverPadding(
                padding: EdgeInsets.only(top: 6),
                sliver: SliverToBoxAdapter(child: SizedBox(height: 0)),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                sliver: SliverList.builder(
                  itemCount: _incoming!.length,
                  itemBuilder: (_, i) {
                    final r = _incoming![i];
                    return Card(
                      key: ValueKey<String>('req-${r.requestId}'),
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: AnimalGlyph(animal: r.otherAnimal, size: 26),
                        title: Text(
                          r.otherDisplayId,
                          style: JCTypography.animalId,
                        ),
                        subtitle: const Text(
                          'wants to talk to you',
                          style: JCTypography.secondary,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'Deny',
                              icon: Icon(
                                Icons.close_rounded,
                                color: JCColors.danger,
                              ),
                              onPressed: FeedbackService.click(
                                () => _respond(r.requestId, false),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Accept',
                              icon: const Icon(
                                Icons.check_rounded,
                                color: JCColors.accent,
                              ),
                              onPressed: FeedbackService.click(
                                () => _respond(r.requestId, true),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SliverPadding(
                padding: EdgeInsets.only(top: 14),
                sliver: SliverToBoxAdapter(child: SizedBox(height: 0)),
              ),
            ],

            // ---- Groups ------------------------------------------------
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              sliver: SliverToBoxAdapter(
                child: Row(
                  children: [
                    Text(
                      'GROUPS',
                      style: JCTypography.secondary.copyWith(
                        fontSize: 12,
                        letterSpacing: 2,
                      ),
                    ),
                    const Spacer(),
                    GestureDetector(
                      onTap: FeedbackService.click(
                        () => context.push('/create-group'),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.add_rounded,
                            size: 18,
                            color: JCColors.accent,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'New',
                            style: JCTypography.secondary.copyWith(
                              color: JCColors.accent,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SliverPadding(
              padding: EdgeInsets.only(top: 6),
              sliver: SliverToBoxAdapter(child: SizedBox(height: 0)),
            ),
            if (_groups != null && _groups!.isEmpty)
              const SliverPadding(
                padding: EdgeInsets.symmetric(vertical: 20),
                sliver: SliverToBoxAdapter(
                  child: Center(
                    child: Text(
                      'No groups yet.\nCreate one to chat with multiple animals.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        color: JCColors.textSecondary,
                      ),
                    ),
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                sliver: SliverList.builder(
                  itemCount: _groups?.length ?? 0,
                  itemBuilder: (_, i) {
                    final g = _groups![i];
                    final hasUnread = g.unreadCount > 0;
                    return ListTile(
                      key: ValueKey<String>('grp-${g.id}'),
                      contentPadding: const EdgeInsets.symmetric(vertical: 2),
                      leading: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: JCColors.accentDim,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(
                          Icons.group_rounded,
                          color: JCColors.accent,
                          size: 22,
                        ),
                      ),
                      title: Text(
                        g.name,
                        style: JCTypography.body.copyWith(
                          fontWeight: hasUnread
                              ? FontWeight.w800
                              : FontWeight.w600,
                        ),
                      ),
                      subtitle: hasUnread
                          ? Text(
                              'new message',
                              maxLines: 1,
                              style: JCTypography.secondary.copyWith(
                                color: JCColors.accent,
                                fontWeight: FontWeight.w600,
                              ),
                            )
                          : Text(
                              g.lastMessage == null
                                  ? '${g.memberCount} members'
                                  : g.lastMessage!,
                              maxLines: 1,
                              style: JCTypography.secondary,
                            ),
                      trailing: hasUnread
                          ? Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: const BoxDecoration(
                                color: JCColors.danger,
                                borderRadius: BorderRadius.all(
                                  Radius.circular(10),
                                ),
                              ),
                              child: Text(
                                '${g.unreadCount}',
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            )
                          : Text(
                              '${g.memberCount}',
                              style: JCTypography.secondary,
                            ),
                      onTap: FeedbackService.click(() async {
                        await context.push(
                          '/group/${g.id}',
                          extra: {'name': g.name},
                        );
                        await _load();
                      }),
                    );
                  },
                ),
              ),
            const SliverPadding(
              padding: EdgeInsets.only(top: 14),
              sliver: SliverToBoxAdapter(child: SizedBox(height: 0)),
            ),

            // ---- Conversations -----------------------------------------
            const SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              sliver: SliverToBoxAdapter(
                child: Text(
                  'CONVERSATIONS',
                  style: TextStyle(
                    fontSize: 12,
                    letterSpacing: 2,
                    color: JCColors.textSecondary,
                  ),
                ),
              ),
            ),
            const SliverPadding(
              padding: EdgeInsets.only(top: 6),
              sliver: SliverToBoxAdapter(child: SizedBox(height: 0)),
            ),
            if (_conversations != null && _conversations!.isEmpty)
              SliverPadding(
                padding: const EdgeInsets.symmetric(vertical: 40),
                sliver: SliverToBoxAdapter(
                  child: Center(
                    child: Text(
                      _incoming != null && _incoming!.isNotEmpty
                          ? 'No conversations yet.\nAccept a request above to start.'
                          : 'No private conversations yet.\n'
                                'Meet an animal and request to talk.',
                      textAlign: TextAlign.center,
                      style: JCTypography.secondary,
                    ),
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                sliver: SliverList.builder(
                  itemCount: _conversations?.length ?? 0,
                  itemBuilder: (_, i) {
                    final c = _conversations![i];
                    final hasUnread = c.unreadCount > 0;
                    final isOfficial = _official.contains(c.id);
                    final title = isOfficial ? 'Adam' : c.otherDisplayId;
                    return ListTile(
                      key: ValueKey<String>('conv-${c.id}'),
                      contentPadding: const EdgeInsets.symmetric(vertical: 2),
                      leading: _ConversationLeading(
                        // Extracted widget — its build only depends on this
                        // conversation's fields, not on the whole list, so
                        // an unread-count change for row N doesn't drag
                        // row M through the rasterizer.
                        conversation: c,
                        isOfficial: isOfficial,
                      ),
                      title: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              title,
                              overflow: TextOverflow.ellipsis,
                              style: JCTypography.animalId.copyWith(
                                fontWeight: hasUnread
                                    ? FontWeight.w800
                                    : FontWeight.w600,
                              ),
                            ),
                          ),
                          if (isOfficial) ...[
                            const SizedBox(width: 4),
                            const Icon(
                              Icons.verified_rounded,
                              size: 16,
                              color: JCColors.accent,
                            ),
                          ],
                        ],
                      ),
                      subtitle: hasUnread
                          ? Text(
                              'new message',
                              maxLines: 1,
                              style: JCTypography.secondary.copyWith(
                                color: JCColors.accent,
                                fontWeight: FontWeight.w600,
                              ),
                            )
                          : Text(
                              c.lastMessageAt == null
                                  ? 'say hello'
                                  : 'last message ${_shortTime(c.lastMessageAt!)}',
                              maxLines: 1,
                              style: JCTypography.secondary,
                            ),
                      trailing: hasUnread
                          ? Text(
                              '${c.unreadCount} new',
                              style: JCTypography.secondary.copyWith(
                                color: JCColors.accent,
                              ),
                            )
                          : null,
                      onTap: FeedbackService.click(() async {
                        await context.push(
                          '/chat/${c.id}',
                          extra: {'name': title},
                        );
                        await _load();
                      }),
                    );
                  },
                ),
              ),
          ],
        ],
      ),
    );
  }

  String _shortTime(DateTime t) {
    final local = t.toLocal();
    final now = DateTime.now();
    if (local.year == now.year &&
        local.month == now.month &&
        local.day == now.day) {
      return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    }
    return '${local.day}/${local.month}';
  }
}

/// Conversation avatar + unread badge + online dot in one extracted widget.
///
/// Lives outside the build() closure so Flutter can mark its element as
/// "depend only on the conversation fields passed in" — the parent rebuild
/// will then diff cheaply, and an unread-count change for row N no longer
/// drags row M through the widget tree.
class _ConversationLeading extends StatelessWidget {
  final ConversationView conversation;
  final bool isOfficial;

  const _ConversationLeading({
    required this.conversation,
    required this.isOfficial,
  });

  @override
  Widget build(BuildContext context) {
    final c = conversation;
    final hasUnread = c.unreadCount > 0;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // Tap the avatar to open the animal's profile.
      onTap: isOfficial
          ? null
          : FeedbackService.click(
              () => context.push(
                '/profile/${c.otherId}',
                extra: {'displayId': c.otherDisplayId, 'animal': c.otherAnimal},
              ),
            ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          isOfficial
              ? CircleAvatar(
                  radius: 14,
                  backgroundColor: JCColors.accentDim,
                  child: const Icon(
                    Icons.support_agent_rounded,
                    size: 18,
                    color: JCColors.accent,
                  ),
                )
              : AnimalGlyph(animal: c.otherAnimal, size: 28),
          if (hasUnread)
            Positioned(
              right: -4,
              top: -4,
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: const BoxDecoration(
                  color: JCColors.danger,
                  shape: BoxShape.circle,
                ),
                constraints: const BoxConstraints(minWidth: 18),
                child: Text(
                  '${c.unreadCount}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 10,
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          if (c.otherIsOnline && !isOfficial)
            Positioned(
              right: -2,
              bottom: -2,
              child: Container(
                width: 11,
                height: 11,
                decoration: BoxDecoration(
                  color: JCColors.onlineGreen,
                  shape: BoxShape.circle,
                  border: Border.all(color: JCColors.background, width: 2),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
