import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/animal_glyph.dart';
import '../../core/theme.dart';
import '../../services/chat_service.dart';
import '../../services/feedback_service.dart';
import '../../services/group_service.dart';
import '../../services/social_service.dart';

import '../home/home_shell.dart';

/// PRD §24 — direct interaction, no feed.
final socialServiceProvider = Provider<SocialService>((_) => SocialService());
final chatServiceProvider = Provider<ChatService>((_) => ChatService());
final groupServiceProvider = Provider<GroupService>((_) => GroupService());

/// The conversation currently open (if any) - used to suppress banner
/// noise for the chat the user is already reading.
final ValueNotifier<String?> currentOpenConversationId = ValueNotifier<String?>(
  null,
);

/// The group currently open (if any) - used to suppress banner
/// noise for the group chat the user is already reading.
final ValueNotifier<String?> currentOpenGroupId = ValueNotifier<String?>(null);

/// Unread notifications badge count (actionable items only).
final unreadCountProvider = FutureProvider.autoDispose<int>((ref) async {
  // Server-side COUNT (limit(0) transfers no rows): previously every unread
  // ROW was fetched just to take its length — on every realtime notification
  // event and every tab tap.
  final res = await Supabase.instance.client
      .from('notifications')
      .select('id')
      .inFilter('kind', [
        'talk_request',
        'new_message',
        'official_message',
        'group_message',
        'group_invitation',
        'group_added',
      ])
      .isFilter('read_at', null)
      .limit(0)
      .count(CountOption.exact);
  return res.count;
});

/// The "Animals" tab (PRD §24 — direct interaction, no feed). Discovery
/// entry points live here; notifications are a dedicated nav tab.
class AnimalsTab extends ConsumerWidget {
  const AnimalsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(myProfileProvider);

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      children: [
        Center(
          child: Column(
            children: [
              Text('JungleChat', style: JCTypography.title),
              const SizedBox(height: 10),
              profile.maybeWhen(
                data: (p) => p == null
                    ? const SizedBox()
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AnimalGlyph(animal: p.animal, size: 22),
                          const SizedBox(width: 8),
                          Text(
                            p.displayAnimalId,
                            style: JCTypography.animalId.copyWith(fontSize: 17),
                          ),
                        ],
                      ),
                orElse: () => const SizedBox(height: 24),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        FilledButton.icon(
          onPressed: FeedbackService.click(() => context.push('/meet')),
          icon: const Icon(Icons.pets),
          label: const Text('MEET THE ANIMALS'),
        ),
        const SizedBox(height: 10),
        ElevatedButton.icon(
          onPressed: FeedbackService.click(() => context.push('/random')),
          icon: const Icon(Icons.casino_outlined),
          label: const Text('RANDOM TALK'),
        ),
        const SizedBox(height: 10),
        ElevatedButton.icon(
          onPressed: FeedbackService.click(() async {
            final id = await context.push('/scan');
            if (id is String && context.mounted) context.push('/animal/$id');
          }),
          icon: const Icon(Icons.qr_code_scanner),
          label: const Text('SCAN QR CODE'),
        ),
        const SizedBox(height: 10),
        ElevatedButton.icon(
          onPressed: FeedbackService.click(() => context.push('/search')),
          icon: const Icon(Icons.search),
          label: const Text('FIND AN ANIMAL'),
        ),
      ],
    );
  }
}
