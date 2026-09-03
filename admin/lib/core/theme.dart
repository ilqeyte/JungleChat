import 'package:flutter/material.dart';

/// JungleChat admin palette. Pure-black chrome (navigation rail, app bars),
/// moss-green accent. Mirrors the mobile app's brand without copying its logo.
class JCColors {
  static const Color bg = Color(0xFF0B0B0B);
  static const Color surface = Color(0xFF161616);
  static const Color surface2 = Color(0xFF1F1F1F);
  static const Color accent = Color(0xFF8FBF9F); // moss green
  static const Color text = Color(0xFFEDEDED);
  static const Color muted = Color(0xFF9A9A9A);
  static const Color danger = Color(0xFFE57373);
  static const Color warn = Color(0xFFE0A458);
}

ThemeData jungleAdminTheme() {
  return ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: JCColors.bg,
    colorScheme: ColorScheme.dark(
      primary: JCColors.accent,
      surface: JCColors.surface,
      error: JCColors.danger,
    ),
    useMaterial3: true,
    cardTheme: CardThemeData(
      color: JCColors.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: JCColors.bg,
      elevation: 0,
      titleTextStyle: TextStyle(
        color: JCColors.text,
        fontSize: 18,
        fontWeight: FontWeight.w600,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: JCColors.surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
      labelStyle: const TextStyle(color: JCColors.muted),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: JCColors.accent,
        foregroundColor: Colors.black,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: JCColors.text,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    dataTableTheme: const DataTableThemeData(
      headingTextStyle: TextStyle(color: JCColors.muted, fontSize: 12),
      dataTextStyle: TextStyle(color: JCColors.text, fontSize: 13),
    ),
  );
}
