import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Creates the shared Material 3 theme used by every Wristload window.
///
/// A single CJK-capable family prevents Latin and Chinese glyphs in the same
/// label from falling back to different fonts with visibly different weight.
ThemeData buildWristloadTheme({
  required Color seedColor,
  required Brightness brightness,
  VisualDensity? visualDensity,
  InputDecorationTheme? inputDecorationTheme,
}) {
  final generatedScheme = ColorScheme.fromSeed(
    seedColor: seedColor,
    brightness: brightness,
  );
  final isTianyiBlue = seedColor.toARGB32() == 0xFF66CCFF;
  final colorScheme = isTianyiBlue
      ? generatedScheme.copyWith(
          // Dark-mode primaryContainer is intentionally low-luminance and
          // makes Tianyi Blue controls look desaturated. Keep the existing
          // light scheme, but use the unlocked #66CCFF swatch directly for
          // dark-mode primary actions and indicators.
          primary: brightness == Brightness.dark
              ? seedColor
              : generatedScheme.primaryContainer,
          onPrimary: brightness == Brightness.dark
              ? Colors.black
              : generatedScheme.onPrimaryContainer,
          surfaceTint: seedColor,
        )
      : generatedScheme;

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: colorScheme,
    filledButtonTheme: isTianyiBlue
        ? FilledButtonThemeData(
            style: ButtonStyle(
              foregroundColor: WidgetStatePropertyAll(Colors.black),
              iconColor: WidgetStatePropertyAll(Colors.black),
            ),
          )
        : null,
    textButtonTheme: isTianyiBlue
        ? TextButtonThemeData(
            style: ButtonStyle(
              foregroundColor: WidgetStatePropertyAll(Colors.black),
              iconColor: WidgetStatePropertyAll(Colors.black),
            ),
          )
        : null,
    outlinedButtonTheme: isTianyiBlue
        ? OutlinedButtonThemeData(
            style: ButtonStyle(
              foregroundColor: WidgetStatePropertyAll(Colors.black),
              iconColor: WidgetStatePropertyAll(Colors.black),
            ),
          )
        : null,
    fontFamily: _fontFamily,
    fontFamilyFallback: _fontFamilyFallback,
    visualDensity: visualDensity,
    inputDecorationTheme: inputDecorationTheme,
  );
}

String get _fontFamily => switch (defaultTargetPlatform) {
  TargetPlatform.windows => 'Microsoft YaHei UI',
  TargetPlatform.macOS => 'PingFang SC',
  TargetPlatform.iOS => 'PingFang SC',
  TargetPlatform.android => 'Noto Sans CJK SC',
  TargetPlatform.linux => 'Noto Sans CJK SC',
  TargetPlatform.fuchsia => 'Noto Sans CJK SC',
};

List<String> get _fontFamilyFallback => switch (defaultTargetPlatform) {
  TargetPlatform.windows => const <String>['Microsoft YaHei', 'Segoe UI'],
  TargetPlatform.macOS ||
  TargetPlatform.iOS => const <String>['PingFang SC', '.AppleSystemUIFont'],
  TargetPlatform.android || TargetPlatform.linux || TargetPlatform.fuchsia =>
    const <String>['Noto Sans CJK SC', 'Noto Sans SC', 'sans-serif'],
};
