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
