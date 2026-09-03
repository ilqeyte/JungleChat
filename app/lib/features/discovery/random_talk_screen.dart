import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/safe_errors.dart';
import '../../core/theme.dart';
import '../../services/auth_service.dart';
import '../../services/feedback_service.dart';
import '../../core/animal_glyph.dart';
import '../home/home_tab.dart';

/// PRD §21 — Random Talk. The server picks ONE eligible candidate; contact
/// still happens through an explicit talk request (never automatic access).
class RandomTalkScreen extends ConsumerStatefulWidget {
  const RandomTalkScreen({super.key});

  @override
  ConsumerState<RandomTalkScreen> createState() => _RandomTalkScreenState();
}

class _RandomTalkScreenState extends ConsumerState<RandomTalkScreen> {
  AnimalCard? _candidate;
  bool _busy = false;
  String? _note;

  Future<void> _roll() async {
    setState(() {
      _busy = true;
      _note = null;
      _candidate = null;
    });
    try {
      final c = await ref.read(socialServiceProvider).randomCandidate();
      setState(() {
        _candidate = c;
        if (c == null) {
          _note = 'No animal is available right now. Try again soon.';
        }
      });
    } catch (e) {
      setState(() => _note = SafeErrors.message(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('RANDOM TALK')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_busy) ...[
                const SizedBox(
                  width: 44,
                  height: 44,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: JCColors.accent,
                  ),
                ),
                const SizedBox(height: 18),
                const Text(
                  'Listening for an animal…',
                  style: JCTypography.secondary,
                ),
              ] else if (_candidate != null) ...[
                AnimalGlyph(animal: _candidate!.animal, size: 64),
                const SizedBox(height: 14),
                Text(
                  _candidate!.displayAnimalId,
                  style: JCTypography.animalId.copyWith(fontSize: 22),
                ),
                const SizedBox(height: 26),
                FilledButton(
                  onPressed: FeedbackService.click(() async {
                    try {
                      await ref
                          .read(socialServiceProvider)
                          .sendTalkRequest(_candidate!.id);
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Talk request sent.')),
                      );
                      Navigator.pop(context);
                    } catch (e) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(SafeErrors.message(e))),
                      );
                    }
                  }),
                  child: const Text('REQUEST TO TALK'),
                ),
              ] else ...[
                Icon(
                  Icons.casino_outlined,
                  size: 56,
                  color: JCColors.textSecondary.withValues(alpha: .6),
                ),
                const SizedBox(height: 16),
                Text(
                  _note ?? 'Meet a random animal who wants to talk.',
                  textAlign: TextAlign.center,
                  style: JCTypography.secondary,
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: FeedbackService.click(_roll),
                  child: const Text('FIND AN ANIMAL'),
                ),
              ],
              if (!_busy && _candidate != null) ...[
                const SizedBox(height: 12),
                TextButton(
                  onPressed: FeedbackService.click(_roll),
                  child: const Text('Find another'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
