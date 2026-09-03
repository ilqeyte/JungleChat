import 'package:flutter/material.dart';

/// JungleChat visual language (PRD §54–56):
/// dark, cozy, mysterious, modern, restrained. Never "hacker neon".
/// Readability for older users is non-negotiable: high contrast, large
/// targets, familiar controls.
class JCColors {
  // Phase 7 (item #9): pure black. background/surface/surfaceHigh/outline
  // darkened to true black (#000000) / near-black so OLED panels render real
  // black and chrome disappears against the background. text/accent untouched
  // (already clear WCAG AA on black).
  static const background = Color(0xFF000000);
  static const surface = Color(0xFF0B0B0B);
  static const surfaceHigh = Color(0xFF141414);
  static const outline = Color(0xFF262626);
  static const textPrimary = Color(0xFFE8ECEA);
  static const textSecondary = Color(0xFF9AA6A2);
  static const accent = Color(0xFF8FBF9F); // soft moss glow
  static const accentDim = Color(0xFF41594C);
  static const danger = Color(0xFFC97A6D);
  static const onlineGreen = Color(0xFF79B47F);

  /// Subtle jungle gradient for incoming/other message bubbles — a tasteful
  /// dark-green wash over near-black. Keeps text high-contrast.
  static const jungleGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF15281D), Color(0xFF0E1813)],
  );

  /// Slightly deeper moss gradient for the user's own ("mine") bubbles.
  static const jungleGradientMine = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF1E3A2B), Color(0xFF163022)],
  );
}

class JCTypography {
  static const display = TextStyle(
    fontSize: 28,
    fontWeight: FontWeight.w700,
    letterSpacing: 1.5,
    color: JCColors.textPrimary,
  );
  static const title = TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.w600,
    color: JCColors.textPrimary,
  );
  static const body = TextStyle(fontSize: 16, color: JCColors.textPrimary);
  static const secondary = TextStyle(
    fontSize: 14,
    color: JCColors.textSecondary,
  );

  /// Animal IDs and technical labels always render in monospace.
  static const animalId = TextStyle(
    fontFamily: 'monospace',
    fontSize: 15,
    fontWeight: FontWeight.w600,
    letterSpacing: 1.2,
    color: JCColors.accent,
  );
}

ThemeData buildJungleTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: JCColors.background,
    colorScheme: base.colorScheme.copyWith(
      primary: JCColors.accent,
      secondary: JCColors.accent,
      surface: JCColors.surface,
      error: JCColors.danger,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: JCColors.background,
      elevation: 0,
      centerTitle: true,
      titleTextStyle: JCTypography.title,
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: JCColors.surfaceHigh,
        foregroundColor: JCColors.textPrimary,
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        side: const BorderSide(color: JCColors.outline),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: JCColors.accent,
        foregroundColor: JCColors.background,
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: JCColors.surface,
      hintStyle: JCTypography.secondary,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: JCColors.outline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: JCColors.outline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: JCColors.accent),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: JCColors.surfaceHigh,
      contentTextStyle: JCTypography.body,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    dividerColor: JCColors.outline,
    cardTheme: CardThemeData(
      color: JCColors.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: JCColors.outline),
      ),
    ),
  );
}
