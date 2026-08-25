import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Owns the app-wide seed color and persists it independently of theme mode.
class ThemeController extends ChangeNotifier {
  ThemeController(
    Color initialSeed, {
    bool tianyiBlueUnlocked = false,
    SharedPreferences? preferences,
  }) : _seedColor = initialSeed,
       _tianyiBlueUnlocked = tianyiBlueUnlocked,
       _preferences = preferences;

  static const preferenceKey = 'theme_seed_color';
  static const tianyiBlueUnlockedPreferenceKey = 'theme_tianyi_blue_unlocked';
  static const defaultSeedColor = Color(0xFF6750A4);
  static const tianyiBlue = Color(0xFF66CCFF);

  Color _seedColor;
  bool _tianyiBlueUnlocked;
  SharedPreferences? _preferences;

  Color get seedColor => _seedColor;
  bool get tianyiBlueUnlocked => _tianyiBlueUnlocked;

  static Future<ThemeController> create() async {
    final preferences = await SharedPreferences.getInstance();
    final value = preferences.getInt(preferenceKey);
    return ThemeController(
      value == null ? defaultSeedColor : Color(value),
      tianyiBlueUnlocked:
          preferences.getBool(tianyiBlueUnlockedPreferenceKey) ?? false,
      preferences: preferences,
    );
  }

  Future<void> setSeed(Color color) async {
    if (_seedColor.toARGB32() == color.toARGB32()) return;
    _seedColor = color;
    notifyListeners();
    final preferences = _preferences ??= await SharedPreferences.getInstance();
    await preferences.setInt(preferenceKey, color.toARGB32());
  }

  Future<void> unlockTianyiBlue() async {
    final colorChanged = _seedColor.toARGB32() != tianyiBlue.toARGB32();
    final unlockChanged = !_tianyiBlueUnlocked;
    if (!colorChanged && !unlockChanged) return;

    _seedColor = tianyiBlue;
    _tianyiBlueUnlocked = true;
    notifyListeners();

    final preferences = _preferences ??= await SharedPreferences.getInstance();
    await Future.wait([
      preferences.setInt(preferenceKey, tianyiBlue.toARGB32()),
      preferences.setBool(tianyiBlueUnlockedPreferenceKey, true),
    ]);
  }
}
