import 'package:flutter/material.dart';

class AppColors {
  static const primary = Color(0xFF1DB954);
  static const background = Color(0xFF121212);
  static const surface = Color(0xFF1E1E1E);
  static const surfaceVariant = Color(0xFF282828);
  static const textPrimary = Color(0xFFFFFFFF);
  static const textSecondary = Color(0xFFB3B3B3);
  static const error = Color(0xFFCF6679);
}

ThemeData buildDarkTheme() {
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: const ColorScheme.dark(
      primary: AppColors.primary,
      surface: AppColors.surface,
      surfaceContainerHighest: AppColors.surfaceVariant,
      background: AppColors.background,
      onBackground: AppColors.textPrimary,
      onSurface: AppColors.textPrimary,
      onPrimary: Colors.black,
      error: AppColors.error,
    ),
    scaffoldBackgroundColor: AppColors.background,
    fontFamily: 'SpotifyMix',
    textTheme: const TextTheme(
      displayLarge: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold),
      displayMedium: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold),
      titleLarge: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold, fontSize: 20),
      titleMedium: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w500, fontSize: 16),
      titleSmall: TextStyle(color: AppColors.textSecondary, fontSize: 14),
      bodyLarge: TextStyle(color: AppColors.textPrimary, fontSize: 16),
      bodyMedium: TextStyle(color: AppColors.textSecondary, fontSize: 14),
      bodySmall: TextStyle(color: AppColors.textSecondary, fontSize: 12),
      labelLarge: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w600, fontSize: 14),
    ),
    cardTheme: CardThemeData(
      color: AppColors.surfaceVariant,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surfaceVariant,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide.none,
      ),
      hintStyle: const TextStyle(color: AppColors.textSecondary),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.black,
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
        textStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
      ),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.background,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: AppColors.textPrimary,
        fontWeight: FontWeight.bold,
        fontSize: 22,
        fontFamily: 'SpotifyMix',
      ),
      iconTheme: IconThemeData(color: AppColors.textPrimary),
    ),
    iconTheme: const IconThemeData(color: AppColors.textPrimary),
    dividerTheme: const DividerThemeData(color: AppColors.surfaceVariant, thickness: 1),
    sliderTheme: const SliderThemeData(
      activeTrackColor: AppColors.primary,
      inactiveTrackColor: AppColors.surfaceVariant,
      thumbColor: AppColors.primary,
      overlayColor: Color(0x2A1DB954),
      trackHeight: 4,
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: FadeUpwardsPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.linux: FadeUpwardsPageTransitionsBuilder(),
        TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder(),
        TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
      },
    ),
  );
}
