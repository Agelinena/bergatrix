import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../core/constants.dart';

part 'api_client.g.dart';

const _storage = FlutterSecureStorage();
const _tokenKey = 'auth_token';

class ApiClient {
  late final Dio _dio;

  ApiClient() {
    _dio = Dio(BaseOptions(
      baseUrl: kApiBaseUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 30),
      headers: {'Content-Type': 'application/json'},
    ));

    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) async {
        final token = await _storage.read(key: _tokenKey);
        if (token != null) {
          options.headers['Authorization'] = 'Bearer $token';
        }
        handler.next(options);
      },
      onError: (error, handler) {
        handler.next(error);
      },
    ));
  }

  Dio get dio => _dio;

  Future<void> saveToken(String token) async {
    await _storage.write(key: _tokenKey, value: token);
  }

  Future<String?> getToken() async {
    return _storage.read(key: _tokenKey);
  }

  Future<void> clearToken() async {
    await _storage.delete(key: _tokenKey);
  }

  // Auth
  Future<Map<String, dynamic>> login(String email, String password) async {
    final resp = await _dio.post('/api/auth/login', data: {'email': email, 'password': password});
    return resp.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> register(String username, String email, String password) async {
    final resp = await _dio.post('/api/auth/register', data: {
      'username': username,
      'email': email,
      'password': password,
    });
    return resp.data as Map<String, dynamic>;
  }

  Future<void> logout() async {
    try { await _dio.post('/api/auth/logout'); } catch (_) {}
    await clearToken();
  }

  Future<Map<String, dynamic>> getMe() async {
    final resp = await _dio.get('/api/auth/me');
    return resp.data as Map<String, dynamic>;
  }

  // Search
  Future<Map<String, dynamic>> search(String query, {String source = 'deezer'}) async {
    final resp = await _dio.get('/api/search', queryParameters: {'q': query, 'source': source});
    return resp.data as Map<String, dynamic>;
  }

  // Register track
  Future<void> registerTrack(Map<String, dynamic> track) async {
    await _dio.post('/api/tracks/register', data: track);
  }

  // Playlists
  Future<List<dynamic>> getPlaylists() async {
    final resp = await _dio.get('/api/playlists');
    return resp.data as List<dynamic>;
  }

  Future<Map<String, dynamic>> createPlaylist(String name, {String? description}) async {
    final resp = await _dio.post('/api/playlists', data: {'name': name, 'description': description});
    return resp.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getPlaylist(String id) async {
    final resp = await _dio.get('/api/playlists/$id');
    return resp.data as Map<String, dynamic>;
  }

  Future<void> deletePlaylist(String id) async {
    await _dio.delete('/api/playlists/$id');
  }

  Future<void> addTrackToPlaylist(String playlistId, String trackId) async {
    await _dio.post('/api/playlists/$playlistId/tracks', data: {'track_id': trackId});
  }

  Future<void> removeTrackFromPlaylist(String playlistId, String trackId) async {
    await _dio.delete('/api/playlists/$playlistId/tracks/$trackId');
  }

  // Likes
  Future<void> likeTrack(String trackId) async => _dio.post('/api/likes/$trackId');
  Future<void> unlikeTrack(String trackId) async => _dio.delete('/api/likes/$trackId');
  Future<List<dynamic>> getLikedTracks() async {
    final resp = await _dio.get('/api/library/likes');
    return resp.data as List<dynamic>;
  }

  // History
  Future<void> recordPlay(String trackId, int durationMs, {bool completed = false}) async {
    await _dio.post('/api/history', data: {
      'track_id': trackId,
      'duration_played_ms': durationMs,
      'completed': completed,
    });
  }

  Future<List<dynamic>> getHistory({int page = 1}) async {
    final resp = await _dio.get('/api/history', queryParameters: {'page': page});
    return resp.data as List<dynamic>;
  }

  // Radio
  Future<Map<String, dynamic>> getRadioSeeds(String trackId, {String source = 'deezer'}) async {
    final resp = await _dio.post('/api/radio/seed', data: {
      'track_id': trackId,
      'source': source,
      'limit': 10,
    });
    return resp.data as Map<String, dynamic>;
  }

  // Stream URL — token appended as query param for HTML5 audio (web) which can't set headers
  String streamUrl(String trackId, {String? token}) {
    final base = '$kApiBaseUrl/api/stream/$trackId';
    return token != null ? '$base?token=$token' : base;
  }

  // Prefetch
  Future<void> prefetchTracks(List<String> trackIds) async {
    await _dio.post('/api/queue/prefetch', data: {'track_ids': trackIds});
  }
}

@riverpod
ApiClient apiClient(ApiClientRef ref) => ApiClient();
