import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/animal_glyph.dart';
import '../../core/safe_errors.dart';
import '../../core/theme.dart';
import '../../services/auth_service.dart';
import '../../services/feedback_service.dart';
import '../home/home_tab.dart';
import '../reports/report_sheet.dart';

/// PRD §17 — minimal card: animal glyph, ID, open-to-talk, request button.
/// Auto-refreshes on open and periodically, so a stale empty list never
/// hides animals that came online after the screen was first built.
class MeetAnimalsScreen extends ConsumerStatefulWidget {
  const MeetAnimalsScreen({super.key});

  @override
  ConsumerState<MeetAnimalsScreen> createState() => _MeetAnimalsScreenState();
}

class _MeetAnimalsScreenState extends ConsumerState<MeetAnimalsScreen>
    with WidgetsBindingObserver {
  List<AnimalCard>? _cards;
  String? _error;
  bool _loading = true;
  Timer? _autoRefresh;
  int _reloadEpoch = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    // Light auto-refresh: new animals appear without manual pulling.
    _startAutoRefresh();
  }

  /// The 15s discovery refetch loop pauses while the app is backgrounded —
  /// an invisible screen must not poll the server (battery + quota).
  void _startAutoRefresh() {
    _autoRefresh?.cancel();
    _autoRefresh = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _load(silent: true),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _autoRefresh?.cancel();
      _autoRefresh = null;
    } else if (state == AppLifecycleState.resumed) {
      if (_autoRefresh == null) {
        _load(silent: true);
        _startAutoRefresh();
      }
    }
  }

  @override
  void dispose() {
    _autoRefresh?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    final epoch = ++_reloadEpoch;
    if (!silent) setState(() => _loading = true);
    try {
      final cards = await ref.read(socialServiceProvider).discover();
      if (!mounted || epoch != _reloadEpoch) return;
      setState(() {
        _cards = cards;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || epoch != _reloadEpoch) return;
      setState(() {
        _error = SafeErrors.message(e);
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('MEET THE ANIMALS')),
      body: RefreshIndicator(
        color: JCColors.accent,
        onRefresh: () => _load(),
        child: _loading && _cards == null
            ? const Center(
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: JCColors.accent,
                ),
              )
            : _error != null && _cards == null
            ? ListView(
                children: [
                  const SizedBox(height: 100),
                  Center(
                    child: Text(
                      'Could not load animals.\n$_error',
                      textAlign: TextAlign.center,
                      style: JCTypography.secondary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Center(
                    child: OutlinedButton(
                      onPressed: FeedbackService.click(() => _load()),
                      child: const Text('RETRY'),
                    ),
                  ),
                ],
              )
            : (_cards != null && _cards!.isEmpty)
            ? ListView(
                children: [
                  const SizedBox(height: 120),
                  Center(
                    child: Text(
                      'No animals are open to talk right now.\n'
                      'New animals appear here automatically —\n'
                      'or pull down to refresh.',
                      textAlign: TextAlign.center,
                      style: JCTypography.secondary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Center(
                    child: OutlinedButton(
                      onPressed: FeedbackService.click(() => _load()),
                      child: const Text('REFRESH'),
                    ),
                  ),
                ],
              )
            : ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: _cards!.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) => AnimalCardTile(
                  // Stable key on every tile: when the auto-refresh replaces
                  // [_cards], Flutter can match old ↔ new by identity and
                  // recycle the existing element tree. Without it, every
                  // 15-second refresh tears down and rebuilds every visible
                  // card.
                  key: ValueKey<String>('animal-${_cards![i].id}'),
                  card: _cards![i],
                ),
              ),
      ),
    );
  }
}

class AnimalCardTile extends ConsumerWidget {
  final AnimalCard card;
  const AnimalCardTile({super.key, required this.card});

  /// Profile sheet: everything you can do with this animal in one place.
  void _showProfileSheet(BuildContext context, WidgetRef ref) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: JCColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimalGlyph(animal: card.animal, size: 40),
              const SizedBox(height: 10),
              Text(
                card.displayAnimalId,
                style: JCTypography.animalId.copyWith(fontSize: 20),
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: card.isOnline
                          ? JCColors.onlineGreen
                          : JCColors.textSecondary,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    card.isOnline ? 'Online now' : 'Offline',
                    style: TextStyle(
                      fontSize: 13,
                      color: card.isOnline
                          ? JCColors.onlineGreen
                          : JCColors.textSecondary,
                    ),
                  ),
                ],
              ),
              if (card.bio != null && card.bio!.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  card.bio!,
                  textAlign: TextAlign.center,
                  style: JCTypography.secondary,
                ),
              ],
              const SizedBox(height: 4),
              Text(
                card.openToTalk ? 'Open to Talk' : 'Mine Mode',
                style: TextStyle(
                  fontSize: 13,
                  color: card.openToTalk
                      ? JCColors.onlineGreen
                      : JCColors.textSecondary,
                ),
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: FeedbackService.click(() async {
                  Navigator.pop(sheetCtx);
                  try {
                    await ref
                        .read(socialServiceProvider)
                        .sendTalkRequest(card.id);
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          'Talk request sent to ${card.displayAnimalId}.',
                        ),
                      ),
                    );
                  } catch (e) {
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(SafeErrors.message(e))),
                    );
                  }
                }),
                icon: const Icon(Icons.waving_hand_outlined),
                label: const Text('REQUEST TO TALK'),
              ),
              ListTile(
                leading: const Icon(Icons.block_outlined),
                title: const Text('Block this animal'),
                onTap: FeedbackService.click(() async {
                  Navigator.pop(sheetCtx);
                  try {
                    await ref.read(socialServiceProvider).block(card.id);
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Animal blocked.')),
                    );
                  } catch (e) {
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(SafeErrors.message(e))),
                    );
                  }
                }),
              ),
              ListTile(
                leading: const Icon(Icons.flag_outlined),
                title: const Text('Report this animal'),
                onTap: FeedbackService.click(() {
                  Navigator.pop(sheetCtx);
                  showReportSheet(
                    context,
                    ref,
                    type: 'user_report',
                    targetUser: card.id,
                    contextLine: card.displayAnimalId,
                  );
                }),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasBio = card.bio != null && card.bio!.isNotEmpty;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(vertical: 6),
      leading: AnimalGlyph(animal: card.animal, size: 30),
      title: Text(card.displayAnimalId, style: JCTypography.animalId),
      // Tap the card -> full profile sheet with all actions.
      onTap: FeedbackService.click(() => _showProfileSheet(context, ref)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hasBio)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                card.bio!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: JCTypography.secondary,
              ),
            ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: card.isOnline
                      ? JCColors.onlineGreen
                      : JCColors.textSecondary,
                ),
              ),
              const SizedBox(width: 5),
              Text(
                card.openToTalk ? 'Open to Talk' : 'Mine Mode',
                style: TextStyle(
                  fontSize: 13,
                  color: card.openToTalk
                      ? JCColors.onlineGreen
                      : JCColors.textSecondary,
                ),
              ),
            ],
          ),
        ],
      ),
      trailing: FilledButton(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 40),
          padding: const EdgeInsets.symmetric(horizontal: 18),
        ),
        onPressed: FeedbackService.click(() async {
          try {
            await ref.read(socialServiceProvider).sendTalkRequest(card.id);
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Talk request sent to ${card.displayAnimalId}.'),
              ),
            );
          } catch (e) {
            if (!context.mounted) return;
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text(SafeErrors.message(e))));
          }
        }),
        child: const Text('REQUEST', style: TextStyle(fontSize: 13)),
      ),
      onLongPress: () => showReportSheet(
        context,
        ref,
        type: 'user_report',
        targetUser: card.id,
        contextLine: card.displayAnimalId,
      ),
    );
  }
}
