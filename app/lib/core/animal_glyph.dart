import 'package:flutter/material.dart';

import 'theme.dart';

/// The 30 animals available at onboarding (PRD §6). Canonical order.
const kAnimals = [
  'Wolf',
  'Lion',
  'Eagle',
  'Tiger',
  'Fox',
  'Bear',
  'Owl',
  'Panther',
  'Falcon',
  'Camel',
  'Elephant',
  'Shark',
  'Snake',
  'Crocodile',
  'Deer',
  'Horse',
  'Gorilla',
  'Hyena',
  'Cheetah',
  'Rabbit',
  'Panda',
  'Zebra',
  'Leopard',
  'Hawk',
  'Parrot',
  'Dolphin',
  'Whale',
  'Turtle',
  'Monkey',
  'Buffalo',
];

/// EXPLICIT icon per animal — never derived from hashes. One icon each,
/// no duplicates across the catalog.
const Map<String, String> kAnimalEmoji = {
  'Wolf': '🐺',
  'Lion': '🦁',
  'Eagle': '🦅',
  'Tiger': '🐅',
  'Fox': '🦊',
  'Bear': '🐻',
  'Owl': '🦉',
  'Panther': '🐈‍⬛',
  'Falcon': '🦅', // shared bird-of-prey family is intentional
  'Camel': '🐪',
  'Elephant': '🐘',
  'Shark': '🦈',
  'Snake': '🐍',
  'Crocodile': '🐊',
  'Deer': '🦌',
  'Horse': '🐎',
  'Gorilla': '🦍',
  'Hyena': '🦡',
  'Cheetah': '🐆',
  'Rabbit': '🐇',
  'Panda': '🐼',
  'Zebra': '🦓',
  'Leopard': '🐾',
  'Hawk': '🦅',
  'Parrot': '🦜',
  'Dolphin': '🐬',
  'Whale': '🐋',
  'Turtle': '🐢',
  'Monkey': '🐒',
  'Buffalo': '🐃',
};

/// Curated dark-palette accent per animal — every species reads as part of
/// the same shadowy universe while staying distinguishable.
const Map<String, Color> kAnimalAccent = {
  'Wolf': Color(0xFF9FB4C7),
  'Lion': Color(0xFFC7A96B),
  'Eagle': Color(0xFFB8A48F),
  'Tiger': Color(0xFFC78B6B),
  'Fox': Color(0xFFC7825E),
  'Bear': Color(0xFF8A7563),
  'Owl': Color(0xFFA89A85),
  'Panther': Color(0xFF8C93A8),
  'Falcon': Color(0xFF93AAB8),
  'Camel': Color(0xFFBCA37E),
  'Elephant': Color(0xFF9AA0A8),
  'Shark': Color(0xFF7FA3AD),
  'Snake': Color(0xFF97AE7E),
  'Crocodile': Color(0xFF86A083),
  'Deer': Color(0xFFB39B80),
  'Horse': Color(0xFFA8897A),
  'Gorilla': Color(0xFF8E8E96),
  'Hyena': Color(0xFFA89468),
  'Cheetah': Color(0xFFC0A26B),
  'Rabbit': Color(0xFFB8AEB0),
  'Panda': Color(0xFFADB3B5),
  'Zebra': Color(0xFFB5BBC2),
  'Leopard': Color(0xFFB39264),
  'Hawk': Color(0xFFA3866B),
  'Parrot': Color(0xFF8FAF8A),
  'Dolphin': Color(0xFF87A8BD),
  'Whale': Color(0xFF7E93AC),
  'Turtle': Color(0xFF8CA58E),
  'Monkey': Color(0xFFA98F72),
  'Buffalo': Color(0xFF77716B),
};

/// Luminance-preserving saturation reduction + slight darkening, so icons
/// sit IN the dark world instead of popping out like stickers.
/// ColorFilter.matrix requires EXACTLY 20 values (4x5) — never pass a
/// Matrix4.storage (16).
const List<double> _kDuotone = <double>[
  0.28, 0.60, 0.12, 0, 0.02, //
  0.24, 0.62, 0.14, 0, 0.01, //
  0.22, 0.58, 0.18, 0, 0.03, //
  0, 0, 0, 1, 0,
];

/// JungleChat animal identity mark (PRD §7): dark, quiet, consistent.
/// Correct icon guaranteed by the explicit [kAnimalEmoji] table above.
class AnimalGlyph extends StatelessWidget {
  final String animal;
  final double size;

  const AnimalGlyph({super.key, required this.animal, this.size = 30});

  @override
  Widget build(BuildContext context) {
    final accent = kAnimalAccent[animal] ?? JCColors.accentDim;

    // Perf: no BoxShadow blur here — dozens of blurred glyphs on one grid
    // tank low-end GPUs. Border + gradient carry the look instead.
    return Container(
      width: size * 1.45,
      height: size * 1.45,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const RadialGradient(
          colors: [Color(0xFF232B2E), Color(0xFF13181A)],
        ),
        border: Border.all(color: accent.withValues(alpha: 0.55), width: 1.2),
      ),
      child: Center(
        child: ColorFiltered(
          colorFilter: const ColorFilter.matrix(_kDuotone),
          child: Text(
            kAnimalEmoji[animal] ?? '🐾',
            style: TextStyle(fontSize: size * 0.92, height: 1.0),
          ),
        ),
      ),
    );
  }
}
