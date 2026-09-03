import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/animal_glyph.dart';
import '../../core/safe_errors.dart';
import '../../core/theme.dart';
import '../../services/auth_service.dart' show AnimalCard;
import '../../services/feedback_service.dart';
import '../home/home_tab.dart';

/// Public profile of one animal: identity card, presence and bio.
/// Opened by tapping a chat title, a group member row, a group message
/// sender name, or a chats-list avatar.
class ProfileScreen extends ConsumerStatefulWidget {
  final String userId;

  /// Optional prefill so the header renders instantly while the card loads.
  final String? displayId;
  final String? animal;

  const ProfileScreen({
    super.key,
    required this.userId,
    this.displayId,
    this.animal,
  });

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  AnimalCard? _card;
  bool _loading = true;
  String? _myId;

  @override
  void initState() {
    super.initState();
    _myId = Supabase.instance.client.auth.currentUser?.id;
    _load();
  }

  Future<void> _load() async {
    try {
      final card = await ref
          .read(socialServiceProvider)
          .animalProfile(widget.userId);
      if (!mounted) return;
      setState(() {
        _card = card;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(SafeErrors.message(e))));
    }
  }

  Future<void> _requestTalk() async {
    try {
      await ref.read(socialServiceProvider).sendTalkRequest(widget.userId);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Talk request sent.')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(SafeErrors.message(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final isMe = widget.userId == _myId;
    final displayId = _card?.displayAnimalId ?? widget.displayId ?? '???';
    final animal = _card?.animal ?? widget.animal ?? '';
    final bio = _card?.bio;
    final isOnline = _card?.isOnline ?? false;

    return Scaffold(
      appBar: AppBar(title: const Text('ANIMAL PROFILE')),
      body: SafeArea(
        child: _loading
            ? const Center(
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: JCColors.accent,
                ),
              )
            : _card == null
            ? Center(
                child: Text(
                  'This animal is no longer here.\n'
                  'Their account is gone.',
                  textAlign: TextAlign.center,
                  style: JCTypography.secondary,
                ),
              )
            : ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        children: [
                          Container(
                            width: 96,
                            height: 96,
                            decoration: const BoxDecoration(
                              color: JCColors.surfaceHigh,
                              shape: BoxShape.circle,
                            ),
                            alignment: Alignment.center,
                            child: AnimalGlyph(animal: animal, size: 48),
                          ),
                          const SizedBox(height: 16),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: Text(
                                  displayId,
                                  style: JCTypography.animalId.copyWith(
                                    fontSize: 24,
                                  ),
                                ),
                              ),
                              if (isMe) ...[
                                const SizedBox(width: 6),
                                Text(
                                  '(you)',
                                  style: JCTypography.secondary.copyWith(
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 10),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: isOnline
                                      ? JCColors.onlineGreen
                                      : JCColors.textSecondary.withAlpha(90),
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                isOnline ? 'Online now' : 'Offline',
                                style: JCTypography.secondary,
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _card!.openToTalk ? 'Open to Talk' : 'Mine Mode',
                            style: TextStyle(
                              fontSize: 13,
                              color: _card!.openToTalk
                                  ? JCColors.onlineGreen
                                  : JCColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  // Bio
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'BIO',
                      style: JCTypography.secondary.copyWith(
                        fontSize: 12,
                        letterSpacing: 2,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: JCColors.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: JCColors.outline),
                    ),
                    child: Text(
                      (bio == null || bio.isEmpty) ? 'No bio yet.' : bio,
                      style: (bio == null || bio.isEmpty)
                          ? JCTypography.secondary
                          : JCTypography.body,
                    ),
                  ),
                  // Actions: only for another animal, and talk requests
                  // only when they are open to talk.
                  if (!isMe && _card!.openToTalk) ...[
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: FeedbackService.click(_requestTalk),
                      child: const Text('REQUEST TO TALK'),
                    ),
                  ],
                ],
              ),
      ),
    );
  }
}
