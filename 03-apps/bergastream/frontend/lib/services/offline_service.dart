import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import '../models/track.dart';
import '../core/api_client.dart';

class OfflineService {
  static const _prefKey = 'offline_tracks_json';

  static Future<List<Track>> getDownloadedTracks() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = prefs.getStringList(_prefKey) ?? [];
    return jsonList
        .map((s) => Track.fromJson(jsonDecode(s) as Map<String, dynamic>))
        .toList();
  }

  static Future<bool> isDownloaded(String trackId) async {
    final tracks = await getDownloadedTracks();
    return tracks.any((t) => t.id == trackId);
  }

  static Future<void> download(Track track, ApiClient client) async {
    if (kIsWeb) {
      // Web: apenas registra no backend, não baixa localmente
      await client.dio.post('/api/offline/${track.id}');
      return;
    }

    final dir = await getApplicationDocumentsDirectory();
    final path = '${dir.path}/bergastream/${track.id}.mp3';
    await Directory('${dir.path}/bergastream').create(recursive: true);

    final token = await client.getToken();
    await client.dio.download(
      '/api/stream/${track.id}',
      path,
      options: Options(
        headers: token != null ? {'Authorization': 'Bearer $token'} : {},
      ),
    );

    // Persiste metadados da faixa
    final prefs = await SharedPreferences.getInstance();
    final jsonList = prefs.getStringList(_prefKey) ?? [];
    // Evita duplicata
    jsonList.removeWhere((s) {
      final m = jsonDecode(s) as Map<String, dynamic>;
      return m['id'] == track.id;
    });
    jsonList.add(jsonEncode(track.toJson()));
    await prefs.setStringList(_prefKey, jsonList);

    await client.dio.post('/api/offline/${track.id}');
  }

  static Future<void> remove(String trackId, ApiClient client) async {
    if (!kIsWeb) {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/bergastream/$trackId.mp3');
      if (await file.exists()) await file.delete();
    }

    final prefs = await SharedPreferences.getInstance();
    final jsonList = prefs.getStringList(_prefKey) ?? [];
    jsonList.removeWhere((s) {
      final m = jsonDecode(s) as Map<String, dynamic>;
      return m['id'] == trackId;
    });
    await prefs.setStringList(_prefKey, jsonList);

    await client.dio.delete('/api/offline/$trackId');
  }

  static Future<String?> localPath(String trackId) async {
    if (kIsWeb || !await isDownloaded(trackId)) return null;
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/bergastream/$trackId.mp3';
  }

  /// Where the downloaded MP3s live on the device.  Returns null on web.
  /// Exposed so the Settings screen can show the user the path.
  static Future<String?> downloadsDirectory() async {
    if (kIsWeb) return null;
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/bergastream';
  }

  /// Total disk space (in bytes) used by offline tracks.  Walks the
  /// download dir on disk rather than trusting the SharedPreferences
  /// index in case partial / orphan files exist.
  static Future<int> diskUsageBytes() async {
    if (kIsWeb) return 0;
    final path = await downloadsDirectory();
    if (path == null) return 0;
    final dir = Directory(path);
    if (!await dir.exists()) return 0;
    var total = 0;
    try {
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          try {
            total += await entity.length();
          } catch (_) {}
        }
      }
    } catch (e) {
      debugPrint('[OfflineService] diskUsageBytes error: $e');
    }
    return total;
  }

  /// Number of MP3 files actually present on disk (may differ from the
  /// SharedPreferences-tracked count if downloads were interrupted).
  static Future<int> fileCount() async {
    if (kIsWeb) return 0;
    final path = await downloadsDirectory();
    if (path == null) return 0;
    final dir = Directory(path);
    if (!await dir.exists()) return 0;
    var count = 0;
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File && entity.path.endsWith('.mp3')) count++;
      }
    } catch (_) {}
    return count;
  }

  /// Wipes every offline MP3 and forgets every entry in the index.
  /// Returns the number of files deleted.
  static Future<int> clearAll() async {
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefKey);
      return 0;
    }
    final path = await downloadsDirectory();
    var deleted = 0;
    if (path != null) {
      final dir = Directory(path);
      if (await dir.exists()) {
        try {
          await for (final entity in dir.list(followLinks: false)) {
            if (entity is File) {
              try {
                await entity.delete();
                deleted++;
              } catch (_) {}
            }
          }
        } catch (_) {}
      }
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefKey);
    return deleted;
  }

  /// Human-friendly KiB / MiB / GiB string for [bytes].
  static String formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    final fmt = unit == 0
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(value < 10 ? 2 : (value < 100 ? 1 : 0));
    return '$fmt ${units[unit]}';
  }

  /// Result of a bulk download operation.  Counts what succeeded and what
  /// failed so the UI can show a precise summary.
  static Future<OfflineDownloadResult> downloadPlaylist(
    List<Track> tracks,
    ApiClient client, {
    void Function(int completed, int total, Track current)? onProgress,
  }) async {
    final already = await getDownloadedTracks();
    final alreadyIds = already.map((t) => t.id).toSet();

    int succeeded = 0;
    int failed = 0;
    int skipped = 0;
    final errors = <String, String>{};

    final total = tracks.length;
    var i = 0;
    for (final t in tracks) {
      i++;
      onProgress?.call(i, total, t);
      if (alreadyIds.contains(t.id)) {
        skipped++;
        continue;
      }
      try {
        await download(t, client);
        succeeded++;
        alreadyIds.add(t.id); // Avoid re-downloading dup IDs in same batch.
      } catch (e) {
        failed++;
        errors[t.id] = e.toString();
        debugPrint('[offline] download failed for ${t.id}: $e');
      }
    }

    return OfflineDownloadResult(
      total: total,
      succeeded: succeeded,
      failed: failed,
      skipped: skipped,
      errors: errors,
    );
  }
}

class OfflineDownloadResult {
  final int total;
  final int succeeded;
  final int failed;
  final int skipped;
  final Map<String, String> errors;

  const OfflineDownloadResult({
    required this.total,
    required this.succeeded,
    required this.failed,
    required this.skipped,
    required this.errors,
  });

  bool get allSucceeded => failed == 0;
  bool get anyFailed => failed > 0;
}
