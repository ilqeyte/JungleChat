import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/animal_glyph.dart';
import '../../core/safe_errors.dart';
import '../../core/theme.dart';
import '../../services/auth_service.dart';
import '../../services/feedback_service.dart';
import '../home/home_tab.dart';

/// Landing card after scanning a QR (or opening a deep link):
/// shows the animal and the REQUEST TO TALK action — like search results.
class FoundAnimalScreen extends ConsumerStatefulWidget {
  final String animalId;

  const FoundAnimalScreen({super.key, required this.animalId});

  @override
  ConsumerState<FoundAnimalScreen> createState() => _FoundAnimalScreenState();
}

class _FoundAnimalScreenState extends ConsumerState<FoundAnimalScreen> {
  AnimalCard? _card;
  bool _searched = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _search();
  }

  Future<void> _search() async {
    setState(() => _busy = true);
    try {
      final r = await ref
          .read(socialServiceProvider)
          .searchExact(widget.animalId);
      if (!mounted) return;
      setState(() {
        _card = r;
        _searched = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _searched = true);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(SafeErrors.message(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ANIMAL FOUND')),
      body: SafeArea(
        child: _busy && !_searched
            ? const Center(
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: JCColors.accent,
                ),
              )
            : !_searched
            ? const SizedBox.shrink()
            : _card == null
            ? Center(
                child: Text(
                  'This code is not an open animal.\n'
                  'They may be in Mine Mode or gone.',
                  textAlign: TextAlign.center,
                  style: JCTypography.secondary,
                ),
              )
            : ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        children: [
                          AnimalGlyph(animal: _card!.animal, size: 44),
                          const SizedBox(height: 14),
                          Text(
                            _card!.displayAnimalId,
                            style: JCTypography.animalId.copyWith(fontSize: 24),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _card!.openToTalk ? 'Open to Talk' : 'Mine Mode',
                            style: TextStyle(
                              fontSize: 14,
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
                  FilledButton(
                    onPressed: _card!.openToTalk
                        ? FeedbackService.click(() async {
                            try {
                              await ref
                                  .read(socialServiceProvider)
                                  .sendTalkRequest(_card!.id);
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Talk request sent.'),
                                ),
                              );
                            } catch (e) {
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text(SafeErrors.message(e))),
                              );
                            }
                          })
                        : null,
                    child: const Text('REQUEST TO TALK'),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton(
                    onPressed: FeedbackService.click(
                      () => Navigator.pop(context),
                    ),
                    child: const Text('BACK'),
                  ),
                ],
              ),
      ),
    );
  }
}
