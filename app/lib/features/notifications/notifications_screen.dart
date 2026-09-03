import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/safe_errors.dart';
import '../../core/theme.dart';
import '../../services/feedback_service.dart';
import '../home/home_tab.dart';
import '../update/update_flow.dart';

/// In-app notification feed. Every row was written server-side with a
/// privacy-safe template (no Animal IDs, no content — see
/// NOTIFICATION_PRIVACY.md). Tapping routes into the app: message → the
/// sender's chat, group message → that group, invite → accept/ignore,
/// update → the update flow. Details resolve only after authentication.
class NotificationsScreen extends ConsumerStatefulWidget {
  const NotificationsScreen({super.key});

  @override
  ConsumerState<NotificationsScreen> createState() =>
      _NotificationsScreenState();
}

class _NotificationsScreenState extends ConsumerState<NotificationsScreen> {
  List<Map<String, dynamic>>? _items;
  int _installedBuild = 0;
  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    _load();
    _loadInstalledBuild();
    _subscribe();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _loadInstalledBuild() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() => _installedBuild = int.tryParse(info.buildNumber) ?? 0);
    } catch (_) {}
  }

  /// Live updates: a new notification row appears without pull-to-refresh.
  void _subscribe() {
    _sub = Supabase.instance.client
        .from('notifications')
        .stream(primaryKey: ['id'])
        .order('created_at')
        .limit(20)
        .listen((_) {
          ref.invalidate(unreadCountProvider);
          _load(silent: true);
        });
  }

  Future<void> _load({bool silent = false}) async {
    try {
      final rows = await Supabase.instance.client
          .from('notifications')
          .select('id, kind, payload, read_at, created_at')
          .order('created_at', ascending: false)
          .limit(50);
      if (!mounted) return;
      setState(() {
        _items = (rows as List)
            .map((r) => Map<String, dynamic>.from(r))
            .toList();
      });
    } catch (e) {
      if (!mounted || _items != null) return;
      setState(() => _items = []);
    }
  }

  Future<void> _markRead(String id) async {
    await Supabase.instance.client
        .from('notifications')
        .update({'read_at': DateTime.now().toUtc().toIso8601String()})
        .eq('id', id);
    ref.invalidate(unreadCountProvider);
  }

  (String, IconData) _present(String kind) {
    switch (kind) {
      case 'new_message':
        return ('An animal sent you a message.', Icons.chat_bubble_outline);
      case 'official_message':
        return ('Adam sent you a message.', Icons.verified_outlined);
      case 'group_message':
        return ('New message in a group.', Icons.groups_outlined);
      case 'talk_request':
        return ('An animal wants to talk to you.', Icons.waving_hand_outlined);
      case 'talk_accepted':
        return ('Your talk request was accepted.', Icons.check_circle_outline);
      case 'inactivity_warning':
        return (
          'Your account is approaching its inactivity deadline.',
          Icons.hourglass_bottom,
        );
      case 'group_invitation':
        return ('You have been invited to a group.', Icons.group_add);
      case 'group_added':
        return ('You were added to a group.', Icons.groups_outlined);
      case 'app_update':
        return ('A new version is available.', Icons.system_update);
    }
    return ('Notification', Icons.notifications_none);
  }

  /// Update notifications only concern users on an OLDER build. Rows whose
  /// payload version_code is <= the installed build are hidden here, so an
  /// up-to-date user never sees a stale "update available" entry.
  bool _isStaleUpdateRow(Map<String, dynamic> n) {
    if (n['kind'] != 'app_update' || _installedBuild == 0) return false;
    final payload = Map<String, dynamic>.from(n['payload'] as Map? ?? {});
    final code = int.tryParse(payload['version_code']?.toString() ?? '') ?? 0;
    return code <= _installedBuild;
  }

  Future<void> _open(Map<String, dynamic> n) async {
    final kind = n['kind'] as String;
    final payload = Map<String, dynamic>.from(n['payload'] as Map? ?? {});

    // Invites keep their row (accept/ignore happens from the dialog).
    if (kind != 'group_invitation') {
      await _markRead(n['id'] as String);
    }
    if (!mounted) return;

    switch (kind) {
      case 'new_message':
      case 'official_message':
        final cid = payload['conversation_id']?.toString();
        if (cid != null && cid.isNotEmpty) context.push('/chat/$cid');
        break;
      case 'group_message':
        final gid = payload['group_id']?.toString();
        if (gid != null && gid.isNotEmpty) {
          context.push('/group/$gid');
        }
        break;
      case 'group_added':
        final gid = payload['group_id']?.toString();
        if (gid != null && gid.isNotEmpty) {
          context.push('/group/$gid');
        }
        break;
      case 'talk_accepted':
        final cid = payload['conversation_id']?.toString();
        if (cid != null && cid.isNotEmpty) {
          context.push('/chat/$cid');
        } else {
          // Older rows predate the conversation_id payload: land on the
          // Chats tab where the new conversation will be listed.
          context.go('/home');
        }
        break;
      case 'talk_request':
        // Incoming request cards live on the Chats tab.
        context.go('/home');
        break;
      case 'group_invitation':
        await _confirmInvitation(n, payload);
        break;
      case 'app_update':
        await UpdateFlow.checkAndPresent(feedback: true);
        break;
      case 'inactivity_warning':
        break;
    }
  }

  Future<void> _confirmInvitation(
    Map<String, dynamic> n,
    Map<String, dynamic> payload,
  ) async {
    final groupId = payload['group_id']?.toString();
    final groupName = payload['group_name']?.toString();
    final inviterDisplay = payload['inviter_display']?.toString();
    if (groupId == null || groupName == null || inviterDisplay == null) {
      return;
    }

    final accepted = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: JCColors.surface,
        title: Text('Group Invitation', style: JCTypography.title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'You have been invited to join the group:',
              style: JCTypography.body,
            ),
            const SizedBox(height: 8),
            Text(groupName, style: JCTypography.title.copyWith(fontSize: 18)),
            const SizedBox(height: 4),
            Text('From $inviterDisplay', style: JCTypography.secondary),
            const SizedBox(height: 16),
            // OverflowBar: wraps instead of clipping on narrow screens, so
            // ACCEPT is always reachable.
            OverflowBar(
              alignment: MainAxisAlignment.end,
              spacing: 8,
              children: [
                TextButton(
                  onPressed: FeedbackService.click(
                    () => Navigator.pop(ctx, false),
                  ),
                  child: Text(
                    'IGNORE',
                    style: JCTypography.secondary.copyWith(
                      color: JCColors.danger,
                    ),
                  ),
                ),
                FilledButton(
                  onPressed: FeedbackService.click(
                    () => Navigator.pop(ctx, true),
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: JCColors.accent,
                    foregroundColor: Colors.white,
                  ),
                  child: Text(
                    'ACCEPT',
                    style: JCTypography.secondary.copyWith(color: Colors.white),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    if (accepted == null || !mounted) return;

    if (!accepted) {
      try {
        await ref
            .read(groupServiceProvider)
            .rejectGroupInvitation(n['id'] as String);
        await _markRead(n['id'] as String);
        await _load(silent: true);
      } catch (_) {}
      return;
    }

    try {
      // The fixed RPC returns the joined group's id.
      final joinedGroupId = await ref
          .read(groupServiceProvider)
          .acceptGroupInvitation(n['id'] as String);
      await _markRead(n['id'] as String);
      await _load(silent: true);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('You joined the group.')));
      context.push('/group/$joinedGroupId');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(SafeErrors.message(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final visible = _items?.where((n) => !_isStaleUpdateRow(n)).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('NOTIFICATIONS')),
      body: SafeArea(
        child: visible == null
            ? const Center(
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: JCColors.accent,
                ),
              )
            : visible.isEmpty
            ? Center(
                child: Text(
                  'Nothing yet.\nWhen animals reach out,'
                  '\nyou will see it here.',
                  textAlign: TextAlign.center,
                  style: JCTypography.secondary,
                ),
              )
            : RefreshIndicator(
                color: JCColors.accent,
                onRefresh: _load,
                child: ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: visible.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final n = visible[i];
                    final kind = n['kind'] as String;
                    final (text, icon) = _present(kind);
                    final unread = n['read_at'] == null;
                    return ListTile(
                      key: ValueKey<String>('notif-${n['id']}'),
                      leading: Icon(
                        icon,
                        color: unread
                            ? JCColors.accent
                            : JCColors.textSecondary,
                      ),
                      title: Text(text, style: JCTypography.body),
                      subtitle: Text(
                        _ago(n['created_at'] as String),
                        style: JCTypography.secondary,
                      ),
                      trailing: unread
                          ? const Icon(
                              Icons.fiber_manual_record,
                              size: 10,
                              color: JCColors.accent,
                            )
                          : null,
                      onTap: FeedbackService.click(() => _open(n)),
                    );
                  },
                ),
              ),
      ),
    );
  }

  String _ago(String iso) {
    final t = DateTime.parse(iso).toLocal();
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${t.day}/${t.month}';
  }
}
