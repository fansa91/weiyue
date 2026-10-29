import 'package:flutter/material.dart';

class AppColors {
  static const primary = Color(0xFFD33A31); // 网易云红
  static const bg = Color(0xFF141518);
  static const card = Color(0xFF1F2025);
  static const divider = Color(0xFF2A2B31);
  static const textSecondary = Color(0xFF9A9BA0);
}

/// 深色 M3 配色（默认网易云红；[seedColor] 指定时用种子色生成）
ColorScheme _darkScheme({Color? seedColor, bool pureBlack = false}) {
  final base = seedColor == null
      ? const ColorScheme.dark(
          primary: AppColors.primary,
          onPrimary: Colors.white,
          primaryContainer: Color(0xFF7A231D),
          onPrimaryContainer: Color(0xFFFFDAD6),
        )
      : ColorScheme.fromSeed(
          seedColor: seedColor,
          brightness: Brightness.dark,
        );
  if (!pureBlack) {
    return base.copyWith(
      surface: AppColors.bg,
      surfaceContainerLowest: const Color(0xFF0E0F12),
      surfaceContainerLow: AppColors.bg,
      surfaceContainer: const Color(0xFF1B1C21),
      surfaceContainerHigh: const Color(0xFF232429),
      surfaceContainerHighest: AppColors.divider,
    );
  }
  // 纯黑模式（AMOLED）：背景全黑
  return base.copyWith(
    surface: Colors.black,
    surfaceContainerLowest: Colors.black,
    surfaceContainerLow: Colors.black,
    surfaceContainer: const Color(0xFF0A0A0A),
    surfaceContainerHigh: const Color(0xFF141414),
    surfaceContainerHighest: const Color(0xFF1E1E1E),
  );
}

/// 浅色 M3 配色
ColorScheme _lightScheme({Color? seedColor}) {
  if (seedColor == null) {
    return const ColorScheme.light(
      primary: AppColors.primary,
      onPrimary: Colors.white,
      primaryContainer: Color(0xFFFFDAD6),
      onPrimaryContainer: Color(0xFF7A231D),
    );
  }
  return ColorScheme.fromSeed(
    seedColor: seedColor,
    brightness: Brightness.light,
  );
}

/// 构建 M3 主题。
/// [brightness] 明暗，[seedColor] 主题种子色，
/// [pureBlack] 深色下是否纯黑背景。
ThemeData buildTheme({
  required Brightness brightness,
  Color? seedColor,
  bool pureBlack = false,
}) {
  final isDark = brightness == Brightness.dark;
  final ColorScheme scheme;
  if (isDark) {
    scheme = _darkScheme(seedColor: seedColor, pureBlack: pureBlack);
  } else {
    scheme = _lightScheme(seedColor: seedColor);
  }

  final bg = isDark
      ? (pureBlack ? Colors.black : AppColors.bg)
      : scheme.surface;
  final cardColor =
      isDark ? (pureBlack ? const Color(0xFF0A0A0A) : AppColors.card) : scheme.surfaceContainerHigh;

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    scaffoldBackgroundColor: bg,
    colorScheme: scheme,
    appBarTheme: AppBarTheme(
      backgroundColor: bg,
      elevation: 0,
      centerTitle: true,
      titleTextStyle: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: scheme.onSurface,
      ),
      iconTheme: IconThemeData(color: scheme.onSurface),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: bg,
      elevation: 8,
      indicatorColor: scheme.primary.withValues(alpha: 0.25),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return TextStyle(
          fontSize: 12,
          fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
          color: selected ? scheme.primary : Colors.grey,
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(color: selected ? scheme.primary : Colors.grey);
      }),
    ),
    cardTheme: CardThemeData(
      color: cardColor,
      margin: EdgeInsets.zero,
    ),
    dividerTheme: DividerThemeData(
      color: isDark ? AppColors.divider : scheme.outlineVariant,
      thickness: 0.5,
      space: 0,
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: scheme.primary,
      inactiveTrackColor: scheme.onSurface.withValues(alpha: 0.24),
      thumbColor: scheme.primary,
      overlayColor: scheme.primary.withValues(alpha: 0.2),
      trackHeight: 3,
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: scheme.primary,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: cardColor,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      hintStyle: TextStyle(color: scheme.onSurfaceVariant, fontSize: 14),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}
