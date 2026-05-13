import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import '../models/track.dart';
import '../core/api_client.dart';

class OfflineService {
  static const _boxName = 'offline_tracks';
  static late Box<Track> _box;

  static Future<void> init() async {
    _box = await Hive.openBox<Track>(_boxName);
  }

  static List<Track> getDownloadedTracks() => _box.values.toList();

  static bool isDownloaded(String trackId) => _box.containsKey(trackId);

  static Future<void> download(Track track, ApiClient client) async {
    if (kIsWeb) {
      // Web: só registra no backend, não baixa localmente
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
      options: Options(headers: token != null ? {'Authorization': 'Bearer $token'} : {}),
    );

    await _box.put(track.id, track);
    await client.dio.post('/api/offline/${track.id}');
  }

  static Future<void> remove(String trackId, ApiClient client) async {
    if (!kIsWeb) {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/bergastream/$trackId.mp3');
      if (await file.exists()) await file.delete();
    }
    await _box.delete(trackId);
    await client.dio.delete('/api/offline/$trackId');
  }

  static String? localPath(String trackId) {
    if (kIsWeb || !isDownloaded(trackId)) return null;
    return null; // path resolved async — use via download() above
  }
}
