import 'package:flutter/material.dart';

import '../../core/animal_glyph.dart';
import '../../core/theme.dart';
import '../services/feedback_service.dart';

/// Reusable animal picker grid — used by onboarding, search, and
/// change-animal. Single selection, dark tiles, auto-fit labels.
class AnimalPicker extends StatelessWidget {
  final String? selected;
  final ValueChanged<String> onSelect;

  const AnimalPicker({
    super.key,
    required this.selected,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 1.05,
      ),
      itemCount: kAnimals.length,
      itemBuilder: (_, i) {
        final animal = kAnimals[i];
        final selectedNow = animal == selected;
        return InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: FeedbackService.click(() => onSelect(animal)),
          child: Container(
            decoration: BoxDecoration(
              color: selectedNow ? JCColors.accentDim : JCColors.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: selectedNow ? JCColors.accent : JCColors.outline,
                width: selectedNow ? 2 : 1,
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AnimalGlyph(animal: animal, size: 28),
                const SizedBox(height: 6),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    animal.toUpperCase(),
                    style: JCTypography.animalId.copyWith(fontSize: 10),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Full-screen picker sheet with a confirm button.
Future<String?> showAnimalPickerSheet(
  BuildContext context, {
  String title = 'PICK AN ANIMAL',
}) {
  String? selected;
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: JCColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (sheetCtx) => StatefulBuilder(
      builder: (sheetCtx, setSheet) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: JCTypography.title),
            const SizedBox(height: 14),
            SizedBox(
              height: MediaQuery.of(sheetCtx).size.height * 0.5,
              child: SingleChildScrollView(
                child: AnimalPicker(
                  selected: selected,
                  onSelect: (a) => setSheet(() => selected = a),
                ),
              ),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: selected == null
                    ? null
                    : FeedbackService.click(
                        () => Navigator.pop(sheetCtx, selected),
                      ),
                child: Text(
                  selected == null ? 'PICK ONE' : 'CONFIRM $selected',
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
