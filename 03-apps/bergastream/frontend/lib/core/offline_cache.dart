/// Persistent JSON cache for API responses so the app can render
/// library / home / playlists / history while offline.
///
/// Backend payloads stash here as raw JSON strings keyed by endpoint.
/// Providers call [OfflineCache.set] after a successful fetch and
/// [OfflineCache.get] as a fallback when the live fetch fails.
library;

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class OfflineCache {
  OfflineCache._();

  static const _prefix = 'offline_cache_v1_';

  static Future<void> set(String key, Object payload) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('$_prefix$key', jsonEncode(payload));
    } catch (e) {
      debugPrint('[OfflineCache] set("$key") failed: $e');
    }
  }

  /// Returns the decoded JSON or null if absent / unparseable.
  static Future<Object?> get(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('$_prefix$key');
      if (raw == null) return null;
      return jsonDecode(raw);
    } catch (e) {
      debugPrint('[OfflineCache] get("$key") failed: $e');
      return null;
    }
  }

  /// Convenience for the common case where the caller wants a List<dynamic>
  /// (e.g. /playlists, /history).  Returns const [] when missing.
  static Future<List<dynamic>> getList(String key) async {
    final value = await get(key);
    if (value is List) return value;
    return const [];
  }

  /// Convenience for Map<String, dynamic> payloads.
  static Future<Map<String, dynamic>?> getMap(String key) async {
    final value = await get(key);
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return null;
  }

  static Future<void> remove(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_prefix$key');
  }

  /// Wipes every key under our prefix.  Called on logout.
  static Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    final toRemove = prefs.getKeys().where((k) => k.startsWith(_prefix));
    for (final k in toRemove) {
      await prefs.remove(k);
    }
  }
}
