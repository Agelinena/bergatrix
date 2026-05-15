import 'dart:typed_data';
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
      receiveTimeout: const Duration(seconds: 90),
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

  Future<void> changePassword(String currentPassword, String newPassword) async {
    await _dio.post('/api/auth/change-password', data: {
      'current_password': currentPassword,
      'new_password': newPassword,
    });
  }

  Future<Map<String, dynamic>> updateMe({String? username}) async {
    final data = <String, dynamic>{};
    if (username != null) data['username'] = username;
    final resp = await _dio.put('/api/auth/me', data: data);
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

  Future<Map<String, dynamic>> createPlaylist(String name, {String? description, bool isPublic = false}) async {
    final resp = await _dio.post('/api/playlists', data: {
      'name': name,
      if (description != null) 'description': description,
      'is_public': isPublic,
    });
    return resp.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getPlaylist(String id) async {
    final resp = await _dio.get('/api/playlists/$id');
    return resp.data as Map<String, dynamic>;
  }

  Future<void> updatePlaylist(String id, {String? name, String? description, String? coverUrl, bool? isPublic}) async {
    final data = <String, dynamic>{};
    if (name != null) data['name'] = name;
    if (description != null) data['description'] = description;
    if (coverUrl != null) data['cover_url'] = coverUrl;
    if (isPublic != null) data['is_public'] = isPublic;
    await _dio.put('/api/playlists/$id', data: data);
  }

  Future<void> deletePlaylist(String id) async {
    await _dio.delete('/api/playlists/$id');
  }

  Future<Map<String, dynamic>> sharePlaylist(String id) async {
    final resp = await _dio.post('/api/playlists/$id/share');
    return resp.data as Map<String, dynamic>;
  }

  Future<void> addTrackToPlaylist(String playlistId, String trackId, {bool force = false}) async {
    final url = '/api/playlists/$playlistId/tracks${force ? '?force=true' : ''}';
    await _dio.post(url, data: {'track_id': trackId});
  }

  Future<void> removeTrackFromPlaylist(String playlistId, String trackId) async {
    await _dio.delete('/api/playlists/$playlistId/tracks/$trackId');
  }

  Future<String?> uploadPlaylistCover(String playlistId, Uint8List bytes, String mimeType) async {
    final ext = switch (mimeType) {
      'image/png' => 'png',
      'image/webp' => 'webp',
      _ => 'jpg',
    };
    final formData = FormData.fromMap({
      'file': MultipartFile.fromBytes(
        bytes,
        filename: 'cover.$ext',
        contentType: DioMediaType.parse(mimeType),
      ),
    });
    final resp = await _dio.post('/api/playlists/$playlistId/cover', data: formData);
    return (resp.data as Map<String, dynamic>)['cover_url'] as String?;
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
  Future<Map<String, dynamic>> getRadioSeeds(
    String trackId, {
    String source = 'lastfm',
    String title = '',
    String artist = '',
  }) async {
    final resp = await _dio.post('/api/radio/seed', data: {
      'track_id': trackId,
      'source': source,
      'limit': 20,
      if (title.isNotEmpty) 'title': title,
      if (artist.isNotEmpty) 'artist': artist,
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

  // Cache
  Future<void> deleteTrackCache(String trackId) async {
    await _dio.delete('/api/stream/$trackId/cache');
  }

  // Collaborators
  Future<List<dynamic>> getCollaborators(String playlistId) async {
    final resp = await _dio.get('/api/playlists/$playlistId/collaborators');
    return resp.data as List<dynamic>;
  }

  Future<Map<String, dynamic>> addCollaborator(String playlistId, String identifier) async {
    final isEmail = identifier.contains('@');
    final resp = await _dio.post(
      '/api/playlists/$playlistId/collaborators',
      data: isEmail ? {'email': identifier} : {'username': identifier},
    );
    return resp.data as Map<String, dynamic>;
  }

  Future<void> removeCollaborator(String playlistId, String userId) async {
    await _dio.delete('/api/playlists/$playlistId/collaborators/$userId');
  }

  // URL resolve
  Future<Map<String, dynamic>> resolveTrackUrl(String url) async {
    final resp = await _dio.post('/api/resolve/track', data: {'url': url});
    return resp.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> resolvePlaylistUrl(String url) async {
    final resp = await _dio.post('/api/resolve/playlist', data: {'url': url});
    return resp.data as Map<String, dynamic>;
  }

  // Admin
  Future<List<dynamic>> adminListUsers() async {
    final resp = await _dio.get('/api/admin/users');
    return resp.data as List<dynamic>;
  }

  Future<Map<String, dynamic>> adminCreateUser({
    required String username,
    required String email,
    required String password,
    bool isAdmin = false,
  }) async {
    final resp = await _dio.post('/api/admin/users', data: {
      'username': username,
      'email': email,
      'password': password,
      'is_admin': isAdmin,
    });
    return resp.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> adminUpdateUser(
    String userId, {
    bool? isAdmin,
    bool? isActive,
  }) async {
    final data = <String, dynamic>{};
    if (isAdmin != null) data['is_admin'] = isAdmin;
    if (isActive != null) data['is_active'] = isActive;
    final resp = await _dio.patch('/api/admin/users/$userId', data: data);
    return resp.data as Map<String, dynamic>;
  }

  Future<void> adminDeleteUser(String userId) async {
    await _dio.delete('/api/admin/users/$userId');
  }

  // Enfileira todas as faixas de uma playlist para download permanente em background
  Future<Map<String, dynamic>> downloadPlaylistPermanent(String playlistId) async {
    final resp = await _dio.post('/api/playlists/$playlistId/download');
    return resp.data as Map<String, dynamic>;
  }

  // Artist all tracks — backend fetches via albums; first call can take a few seconds
  Future<Map<String, dynamic>> getArtistTracks(String artistId, {int index = 0, int limit = 100}) async {
    final resp = await _dio.get(
      '/api/artist/$artistId/tracks',
      queryParameters: {'index': index, 'limit': limit},
      options: Options(receiveTimeout: const Duration(seconds: 120)),
    );
    return resp.data as Map<String, dynamic>;
  }
}

@riverpod
ApiClient apiClient(ApiClientRef ref) => ApiClient();
