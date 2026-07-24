import 'package:flutter/material.dart';

class AppTheme {
  static const Color primary = Color(0xFF2E75B6);
  static const Color primaryDark = Color(0xFF1A4F8A);
  static const Color accent = Color(0xFF4ECDC4);
  static const Color background = Color(0xFF0F0F1A);
  static const Color surface = Color(0xFF1A1A2E);
  static const Color surfaceVariant = Color(0xFF252540);
  static const Color onSurface = Color(0xFFE0E0E0);
  static const Color onSurfaceMuted = Color(0xFF9E9E9E);
  static const Color error = Color(0xFFCF6679);

  static ThemeData get darkTheme => ThemeData(
        useMaterial3: true,
        colorScheme: const ColorScheme.dark(
          primary: primary,
          secondary: accent,
          surface: surface,
          error: error,
          onPrimary: Colors.white,
          onSecondary: Colors.black,
          onSurface: onSurface,
          onError: Colors.white,
          surfaceContainerHighest: surfaceVariant,
        ),
        scaffoldBackgroundColor: background,
        appBarTheme: const AppBarTheme(
          backgroundColor: surface,
          foregroundColor: onSurface,
          elevation: 0,
          centerTitle: false,
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: surface,
          indicatorColor: primary.withValues(alpha: 0.2),
          labelTextStyle: WidgetStateProperty.all(
            const TextStyle(fontSize: 12, color: onSurface),
          ),
        ),
        cardTheme: CardThemeData(
          color: surface,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        listTileTheme: const ListTileThemeData(
          textColor: onSurface,
          iconColor: onSurfaceMuted,
          contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        ),
        sliderTheme: const SliderThemeData(
          activeTrackColor: primary,
          inactiveTrackColor: surfaceVariant,
          thumbColor: primary,
          overlayColor: Colors.transparent,
          trackHeight: 3,
        ),
        iconTheme: const IconThemeData(color: onSurface),
        textTheme: const TextTheme(
          headlineLarge: TextStyle(
              color: onSurface, fontSize: 28, fontWeight: FontWeight.bold),
          headlineMedium: TextStyle(
              color: onSurface, fontSize: 22, fontWeight: FontWeight.bold),
          titleLarge: TextStyle(
              color: onSurface, fontSize: 18, fontWeight: FontWeight.w600),
          titleMedium: TextStyle(
              color: onSurface, fontSize: 16, fontWeight: FontWeight.w500),
          bodyLarge: TextStyle(color: onSurface, fontSize: 16),
          bodyMedium: TextStyle(color: onSurface, fontSize: 14),
          bodySmall: TextStyle(color: onSurfaceMuted, fontSize: 12),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: surfaceVariant,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          hintStyle: const TextStyle(color: onSurfaceMuted),
        ),
        dividerTheme: const DividerThemeData(
          color: surfaceVariant,
          thickness: 1,
        ),
      );
}
