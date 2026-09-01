import 'package:flutter/material.dart';

/// M-Tek brand tokens — mirrored 1:1 from the website's styles.css.
abstract final class Mtek {
  // Brand palette
  static const brand700 = Color(0xFFA50F1E);
  static const brand600 = Color(0xFFC8102E);
  static const brand500 = Color(0xFFE11D2E);
  static const brand400 = Color(0xFFEF2D3C);
  static const brand300 = Color(0xFFFF5B66);
  static const brandTint = Color(0xFFFDECEE);

  // Deep navy surfaces
  static const navy950 = Color(0xFF060B16);
  static const navy900 = Color(0xFF0A1220);
  static const navy850 = Color(0xFF0D1728);
  static const navy800 = Color(0xFF111D36);
  static const navy700 = Color(0xFF1A2A4A);
  static const navy600 = Color(0xFF24365C);

  // Gold accent
  static const gold500 = Color(0xFFF0A92E);
  static const gold400 = Color(0xFFF7C04A);
  static const goldTint = Color(0xFFFDF3DD);

  // Neutrals (slate)
  static const gray50 = Color(0xFFF8FAFC);
  static const gray100 = Color(0xFFF1F5F9);
  static const gray200 = Color(0xFFE2E8F0);
  static const gray300 = Color(0xFFCBD5E1);
  static const gray400 = Color(0xFF94A3B8);
  static const gray500 = Color(0xFF64748B);
  static const gray600 = Color(0xFF475569);
  static const gray700 = Color(0xFF334155);
  static const gray800 = Color(0xFF1E293B);
  static const gray900 = Color(0xFF0F172A);

  static const ink = Color(0xFF0B1220);
  static const success = Color(0xFF15803D);
  static const successTint = Color(0xFFDCFCE7);
  static const warn = Color(0xFFB45309);
  static const warnTint = Color(0xFFFEF3C7);
  static const danger = Color(0xFFB91C1C);
  static const dangerTint = Color(0xFFFEE2E2);

  static const radius = 16.0;
  static const fontFamily = 'Sora'; // bundle Sora/Poppins assets in M2
}

/// Convenience accessor used by main.dart.
abstract final class MtekTheme {
  static ThemeData light() => mtekLightTheme();
}

/// Material 3 light theme branded for M-Tek.
ThemeData mtekLightTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: Mtek.brand600,
    primary: Mtek.brand600,
    secondary: Mtek.navy800,
    tertiary: Mtek.gold500,
    surface: Colors.white,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: Mtek.gray50,
    fontFamily: Mtek.fontFamily,
    appBarTheme: const AppBarTheme(
      backgroundColor: Mtek.navy900,
      foregroundColor: Colors.white,
      elevation: 0,
      centerTitle: false,
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: Mtek.navy900,
      indicatorColor: Mtek.brand600,
      selectedIconTheme: const IconThemeData(color: Colors.white),
      unselectedIconTheme: const IconThemeData(color: Mtek.gray400),
      selectedLabelTextStyle: const TextStyle(
        color: Colors.white,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
      unselectedLabelTextStyle: const TextStyle(color: Mtek.gray400, fontSize: 12),
    ),
    drawerTheme: const DrawerThemeData(backgroundColor: Mtek.navy900),
    cardTheme: CardThemeData(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Mtek.radius),
        side: const BorderSide(color: Mtek.gray200),
      ),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      side: const BorderSide(color: Mtek.gray200),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: Mtek.brand600,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Mtek.gray200),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Mtek.gray200),
      ),
    ),
    listTileTheme: const ListTileThemeData(iconColor: Mtek.navy700),
  );
}
