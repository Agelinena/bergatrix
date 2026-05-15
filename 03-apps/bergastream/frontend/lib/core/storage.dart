/// Thin wrapper around SharedPreferences for cross-platform key-value storage.
/// Replaces direct dart:html localStorage calls so the app compiles on
/// Android, Linux and Windows as well as web.
library;

import 'package:shared_preferences/shared_preferences.dart';

class AppStorage {
  AppStorage._();

  static SharedPreferences? _prefs;

  /// Must be called once at startup (or lazily — the first call awaits init).
  static Future<SharedPreferences> get _instance async {
    return _prefs ??= await SharedPreferences.getInstance();
  }

  static Future<String?> getString(String key) async {
    final prefs = await _instance;
    return prefs.getString(key);
  }

  static Future<void> setString(String key, String value) async {
    final prefs = await _instance;
    await prefs.setString(key, value);
  }

  static Future<List<String>?> getStringList(String key) async {
    final prefs = await _instance;
    return prefs.getStringList(key);
  }

  static Future<void> setStringList(String key, List<String> value) async {
    final prefs = await _instance;
    await prefs.setStringList(key, value);
  }

  static Future<void> remove(String key) async {
    final prefs = await _instance;
    await prefs.remove(key);
  }
}
