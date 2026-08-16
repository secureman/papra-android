import 'package:flutter/material.dart';

/// Brand tokens from the webapp theme constants
/// (apps/papra-client/src/modules/ui/theme/constants.ts):
/// coral primary in light mode, lime/green primary in dark mode.
abstract final class AppColors {
  // ── Light ────────────────────────────────────────────────────────────────
  static const lightPrimary = Color(0xFFFE7D4D);
  static const lightOnPrimary = Color(0xFF0A0A0A);
  static const lightPrimaryContainer = Color(0xFFFFD6B3);
  static const lightOnPrimaryContainer = Color(0xFF3D1E00);
  static const lightSecondary = Color(0xFFF3F3F3);
  static const lightOnSecondary = Color(0xFF0A0A0A);
  static const lightBackground = Color(0xFFFAFAFA);
  static const lightOnBackground = Color(0xFF0A0A0A);
  static const lightSurface = Color(0xFFFFFFFF);
  static const lightOnSurface = Color(0xFF0A0A0A);
  static const lightSurfaceVariant = Color(0xFFE5E5E5);
  static const lightOnSurfaceVariant = Color(0xFF404040);
  static const lightOutline = Color(0xFFE5E5E5);
  static const lightError = Color(0xFFD32F2F);

  // ── Dark ─────────────────────────────────────────────────────────────────
  static const darkPrimary = Color(0xFFD9FF7A);
  static const darkOnPrimary = Color(0xFF0A0A0A);
  static const darkPrimaryContainer = Color(0xFF4A5A2A);
  static const darkOnPrimaryContainer = Color(0xFFE5FFBA);
  static const darkSecondary = Color(0xFF262626);
  static const darkOnSecondary = Color(0xFFFAFAFA);
  static const darkBackground = Color(0xFF141414);
  static const darkOnBackground = Color(0xFFFAFAFA);
  static const darkSurface = Color(0xFF171717);
  static const darkOnSurface = Color(0xFFFAFAFA);
  static const darkSurfaceVariant = Color(0xFF262626);
  static const darkOnSurfaceVariant = Color(0xFFA3A3A3);
  static const darkOutline = Color(0xFF262626);
  static const darkError = Color(0xFFFF6B6B);
  static const darkOnError = Color(0xFF0A0A0A);
}

ThemeData buildLightTheme() => _buildTheme(
      ColorScheme.light(
        primary: AppColors.lightPrimary,
        onPrimary: AppColors.lightOnPrimary,
        primaryContainer: AppColors.lightPrimaryContainer,
        onPrimaryContainer: AppColors.lightOnPrimaryContainer,
        secondary: AppColors.lightSecondary,
        onSecondary: AppColors.lightOnSecondary,
        surface: AppColors.lightSurface,
        onSurface: AppColors.lightOnSurface,
        surfaceContainerHighest: AppColors.lightSurfaceVariant,
        onSurfaceVariant: AppColors.lightOnSurfaceVariant,
        outline: AppColors.lightOutline,
        error: AppColors.lightError,
      ),
      scaffoldBackground: AppColors.lightBackground,
    );

ThemeData buildDarkTheme() => _buildTheme(
      ColorScheme.dark(
        primary: AppColors.darkPrimary,
        onPrimary: AppColors.darkOnPrimary,
        primaryContainer: AppColors.darkPrimaryContainer,
        onPrimaryContainer: AppColors.darkOnPrimaryContainer,
        secondary: AppColors.darkSecondary,
        onSecondary: AppColors.darkOnSecondary,
        surface: AppColors.darkSurface,
        onSurface: AppColors.darkOnSurface,
        surfaceContainerHighest: AppColors.darkSurfaceVariant,
        onSurfaceVariant: AppColors.darkOnSurfaceVariant,
        outline: AppColors.darkOutline,
        error: AppColors.darkError,
        onError: AppColors.darkOnError,
      ),
      scaffoldBackground: AppColors.darkBackground,
    );

ThemeData _buildTheme(ColorScheme scheme, {required Color scaffoldBackground}) {
  final base = ThemeData(colorScheme: scheme, useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: scaffoldBackground,
    appBarTheme: AppBarTheme(
      backgroundColor: scaffoldBackground,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      centerTitle: false,
      scrolledUnderElevation: 0,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surface,
      indicatorColor: scheme.primaryContainer,
      surfaceTintColor: Colors.transparent,
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, thickness: 1),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
    ),
  );
}
