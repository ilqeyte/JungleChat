import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/animal_glyph.dart';
import '../../core/animal_picker.dart';
import '../../core/safe_errors.dart';
import '../../core/theme.dart';
import '../../services/auth_service.dart';
import '../../services/feedback_service.dart';
import '../home/home_tab.dart';

/// PRD §19, simplified per operator: pick the animal from a grid, type only
/// the number — the name and dash are prefilled. Exact search only.
class SearchAnimalScreen extends ConsumerStatefulWidget {
  const SearchAnimalScreen({super.key});

  @override
  ConsumerState<SearchAnimalScreen> createState() => _SearchAnimalScreenState();
}

class _SearchAnimalScreenState extends ConsumerState<SearchAnimalScreen> {
  String? _animal;
  final _number = TextEditingController();
  AnimalCard? _result;
  bool _searched = false;
  bool _busy = false;

  String? get _query {
    final n = _number.text.trim();
    if (_animal == null || n.isEmpty) return null;
    return '$_animal-$n';
  }

  @override
  void dispose() {
    _number.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _query;
    if (q == null || _busy) return;
    FocusScope.of(context).unfocus();
    setState(() => _busy = true);
    try {
      final r = await ref.read(socialServiceProvider).searchExact(q);
      setState(() {
        _result = r;
        _searched = true;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(SafeErrors.message(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('FIND AN ANIMAL')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              '1. Pick the animal',
              style: JCTypography.secondary.copyWith(fontSize: 13),
            ),
            const SizedBox(height: 8),
            AnimalPicker(
              selected: _animal,
              onSelect: (a) => setState(() {
                _animal = a;
                _result = null;
                _searched = false;
              }),
            ),
            const SizedBox(height: 18),
            Text(
              '2. Type the number',
              style: JCTypography.secondary.copyWith(fontSize: 13),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _number,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(6),
              ],
              style: JCTypography.animalId.copyWith(fontSize: 20),
              decoration: InputDecoration(
                prefixText: '${(_animal ?? 'ANIMAL').toUpperCase()}-',
                prefixStyle: JCTypography.animalId.copyWith(
                  fontSize: 20,
                  color: JCColors.textSecondary,
                ),
                hintText: '427',
              ),
              onSubmitted: (_) {
                FeedbackService.tap();
                _search();
              },
            ),
            const SizedBox(height: 14),
            FilledButton(
              onPressed: (_animal == null || _number.text.isEmpty || _busy)
                  ? null
                  : FeedbackService.click(_search),
              child: Text(_busy ? 'SEARCHING…' : 'SEARCH'),
            ),
            const SizedBox(height: 24),
            if (_searched)
              _result == null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 24),
                        child: Text(
                          'No such animal found.\n'
                          'They may be in Mine Mode.',
                          textAlign: TextAlign.center,
                          style: JCTypography.secondary,
                        ),
                      ),
                    )
                  : Card(
                      child: ListTile(
                        contentPadding: const EdgeInsets.all(16),
                        leading: AnimalGlyph(animal: _result!.animal, size: 34),
                        title: Text(
                          _result!.displayAnimalId,
                          style: JCTypography.animalId.copyWith(fontSize: 18),
                        ),
                        subtitle: Text(
                          _result!.openToTalk ? 'Open to Talk' : 'Mine Mode',
                          style: TextStyle(
                            fontSize: 13,
                            color: _result!.openToTalk
                                ? JCColors.onlineGreen
                                : JCColors.textSecondary,
                          ),
                        ),
                        trailing: FilledButton(
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(0, 42),
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                          ),
                          onPressed: FeedbackService.click(() async {
                            try {
                              await ref
                                  .read(socialServiceProvider)
                                  .sendTalkRequest(_result!.id);
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
                          }),
                          child: const Text(
                            'REQUEST',
                            style: TextStyle(fontSize: 13),
                          ),
                        ),
                      ),
                    ),
          ],
        ),
      ),
    );
  }
}
