import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/animal_glyph.dart';
import '../../core/safe_errors.dart';
import '../../core/theme.dart';
import '../../services/feedback_service.dart';
import '../../services/group_service.dart';

/// Group info / settings screen.
/// Shows members, allows admin to manage, allows leave group.
class GroupInfoScreen extends ConsumerStatefulWidget {
  final String groupId;
  final String? groupName;

  const GroupInfoScreen({super.key, required this.groupId, this.groupName});

  @override
  ConsumerState<GroupInfoScreen> createState() => _GroupInfoScreenState();
}

class _GroupInfoScreenState extends ConsumerState<GroupInfoScreen> {
  GroupInfo? _info;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final info = await GroupService().getGroupInfo(widget.groupId);
      if (!mounted) return;
      setState(() {
        _info = info;
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

  Future<void> _leaveGroup() async {
    final myId = Supabase.instance.client.auth.currentUser?.id ?? '';
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: JCColors.surface,
        title: const Text('Leave Group?', style: JCTypography.title),
        content: Text(
          _info?.isAdmin(myId) == true
              ? 'You are the creator. Leaving will dissolve the group for everyone.'
              : 'You will be removed from this group.',
          style: JCTypography.body,
        ),
        actions: [
          TextButton(
            onPressed: FeedbackService.click(() => Navigator.pop(ctx, false)),
            child: const Text('CANCEL'),
          ),
          TextButton(
            onPressed: FeedbackService.click(() => Navigator.pop(ctx, true)),
            child: Text('LEAVE', style: TextStyle(color: JCColors.danger)),
          ),
        ],
      ),
    );

    if (confirm != true || !mounted) return;

    try {
      final dissolved = await GroupService().removeMember(
        widget.groupId,
        Supabase.instance.client.auth.currentUser!.id,
      );
      if (!mounted) return;
      if (dissolved) {
        // Group dissolved, go home
        context.go('/');
      } else {
        // Left group but group continues: exit group info and group chat screens
        if (!mounted) return;
        context.pop(); // exit group info
        if (!mounted) return;
        context.pop(); // exit group chat
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(SafeErrors.message(e))));
    }
  }

  Future<void> _removeMember(String userId, String name) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: JCColors.surface,
        title: const Text('Remove Member?', style: JCTypography.title),
        content: Text(
          'Remove $name from this group?',
          style: JCTypography.body,
        ),
        actions: [
          TextButton(
            onPressed: FeedbackService.click(() => Navigator.pop(ctx, false)),
            child: const Text('CANCEL'),
          ),
          TextButton(
            onPressed: FeedbackService.click(() => Navigator.pop(ctx, true)),
            child: Text('REMOVE', style: TextStyle(color: JCColors.danger)),
          ),
        ],
      ),
    );

    if (confirm != true || !mounted) return;

    try {
      await GroupService().removeMember(widget.groupId, userId);
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(SafeErrors.message(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final myId = Supabase.instance.client.auth.currentUser?.id ?? '';
    final isAdmin = _info?.isAdmin(myId) ?? false;

    return Scaffold(
      backgroundColor: JCColors.background,
      appBar: AppBar(
        backgroundColor: JCColors.surface,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: FeedbackService.click(() => context.pop()),
        ),
        title: Text(
          _info?.name ?? widget.groupName ?? 'Group Info',
          style: JCTypography.title,
        ),
      ),
      body: _loading
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
                    onPressed: FeedbackService.click(_load),
                    child: const Text('RETRY'),
                  ),
                ],
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Group info card
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: JCColors.surface,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    children: [
                      Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          color: JCColors.accentDim,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: const Icon(
                          Icons.group_rounded,
                          color: JCColors.accent,
                          size: 32,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _info?.name ?? '',
                        style: JCTypography.title,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Created ${_formatDate(_info?.createdAt)}',
                        style: JCTypography.secondary.copyWith(fontSize: 12),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${_info?.members.length ?? 0} members',
                        style: JCTypography.secondary,
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 24),

                // Members header
                Text(
                  'MEMBERS',
                  style: JCTypography.secondary.copyWith(
                    fontSize: 12,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 8),

                // Members list
                ...?_info?.members.map((m) {
                  final isMe = m.userId == myId;
                  final isMemberAdmin = m.role == 'admin';
                  return Container(
                    margin: const EdgeInsets.only(bottom: 4),
                    decoration: BoxDecoration(
                      color: JCColors.surface,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: ListTile(
                      leading: AnimalGlyph(animal: m.animal, size: 28),
                      // Tap a member (avatar or name) to open their profile.
                      onTap: FeedbackService.click(
                        () => context.push(
                          '/profile/${m.userId}',
                          extra: {
                            'displayId': m.displayAnimalId,
                            'animal': m.animal,
                          },
                        ),
                      ),
                      title: Row(
                        children: [
                          Flexible(
                            child: Text(
                              m.displayAnimalId,
                              style: JCTypography.animalId,
                            ),
                          ),
                          if (m.isOnline) ...[
                            const SizedBox(width: 6),
                            Container(
                              width: 8,
                              height: 8,
                              decoration: const BoxDecoration(
                                color: JCColors.onlineGreen,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ],
                          if (isMe) ...[
                            const SizedBox(width: 6),
                            Text(
                              '(you)',
                              style: JCTypography.secondary.copyWith(
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ],
                      ),
                      subtitle:
                          (isMemberAdmin ||
                              (m.bio != null && m.bio!.isNotEmpty))
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (isMemberAdmin)
                                  Text(
                                    'admin',
                                    style: JCTypography.secondary.copyWith(
                                      fontSize: 12,
                                      color: JCColors.accent,
                                    ),
                                  ),
                                if (m.bio != null && m.bio!.isNotEmpty)
                                  Text(
                                    m.bio!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: JCTypography.secondary.copyWith(
                                      fontSize: 12,
                                    ),
                                  ),
                              ],
                            )
                          : null,
                      trailing: isAdmin && !isMe
                          ? IconButton(
                              icon: Icon(
                                Icons.remove_circle_outline_rounded,
                                color: JCColors.danger,
                                size: 20,
                              ),
                              onPressed: FeedbackService.click(
                                () =>
                                    _removeMember(m.userId, m.displayAnimalId),
                              ),
                            )
                          : null,
                    ),
                  );
                }),

                const SizedBox(height: 24),

                // Add members: private groups → admin only.
                if (isAdmin)
                  FilledButton.icon(
                    onPressed: FeedbackService.click(
                      () => context.push(
                        '/add-group-members/${widget.groupId}',
                        extra: {'name': _info?.name},
                      ),
                    ),
                    icon: const Icon(Icons.person_add_rounded),
                    label: const Text('ADD MEMBERS'),
                    style: FilledButton.styleFrom(
                      backgroundColor: JCColors.accent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),

                const SizedBox(height: 12),

                // Leave group button.
                if (_info?.creatorId != myId)
                  OutlinedButton(
                    onPressed: FeedbackService.click(_leaveGroup),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: JCColors.danger.withAlpha(80)),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: Text(
                      'LEAVE GROUP',
                      style: JCTypography.body.copyWith(color: JCColors.danger),
                    ),
                  ),
              ],
            ),
    );
  }

  String _formatDate(DateTime? d) {
    if (d == null) return '';
    return '${d.day}/${d.month}/${d.year}';
  }
}
