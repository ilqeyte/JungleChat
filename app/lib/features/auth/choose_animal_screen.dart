import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/animal_glyph.dart';
import '../../core/theme.dart';
import '../../services/feedback_service.dart';
import 'welcome_screen.dart';

export '../../core/animal_glyph.dart' show kAnimals;

/// PRD §6 — choose exactly one animal during account creation.
class ChooseAnimalScreen extends ConsumerStatefulWidget {
  const ChooseAnimalScreen({super.key});

  @override
  ConsumerState<ChooseAnimalScreen> createState() => _ChooseAnimalScreenState();
}

class _ChooseAnimalScreenState extends ConsumerState<ChooseAnimalScreen> {
  String? _selected;
  bool _busy = false;

  Future<void> _createAccount() async {
    final animal = _selected;
    if (animal == null || _busy) return;
    setState(() => _busy = true);

    final messenger = ScaffoldMessenger.of(context);
    try {
      // Account creation runs entirely server-side (Edge Function + SQL).
      // The recovery credential is returned once and passed to the save
      // screen in-memory only — never persisted, never logged.
      final account = await ref.read(authServiceProvider).createAccount(animal);
      if (!mounted) return;
      context.pushReplacement(
        '/recovery-credential',
        extra: <String, String>{
          'animalId': account.animalId,
          'credential': account.recoveryCredential,
        },
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            e.toString().contains('RATE_LIMITED')
                ? 'Too many attempts. Please wait a while.'
                : 'Could not create the account. Try again.',
          ),
        ),
      );
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('CHOOSE AN ANIMAL')),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
              child: Text(
                'Welcome to JungleChat.\nChoose an animal to become your anonymous identity.',
                textAlign: TextAlign.center,
                style: JCTypography.secondary.copyWith(height: 1.5),
              ),
            ),
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.all(20),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 1.05,
                ),
                itemCount: kAnimals.length,
                itemBuilder: (_, i) {
                  final animal = kAnimals[i];
                  final selected = animal == _selected;
                  return InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: FeedbackService.click(
                      () => setState(() => _selected = animal),
                    ),
                    child: Container(
                      decoration: BoxDecoration(
                        color: selected ? JCColors.accentDim : JCColors.surface,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: selected ? JCColors.accent : JCColors.outline,
                          width: selected ? 2 : 1,
                        ),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          AnimalGlyph(animal: animal, size: 30),
                          const SizedBox(height: 8),
                          Text(
                            animal.toUpperCase(),
                            style: JCTypography.animalId.copyWith(fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(20),
              child: FilledButton(
                onPressed: (_selected == null || _busy)
                    ? null
                    : FeedbackService.click(_createAccount),
                child: Text(_busy ? 'BECOMING…' : 'BECOME THIS ANIMAL'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
