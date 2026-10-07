import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_error.dart';
import '../api/api_dio.dart';
import '../models/playlist_models.dart';
import '../models/search_result.dart';

/// Playlists no servidor (Seção 9, área "Playlists").
abstract interface class PlaylistRepository {
  Future<List<ServerPlaylist>> myPlaylists();
  Future<PlaylistDetail> detail(String id);
  Future<ServerPlaylist> create(String name);
  Future<void> rename(String id, String name);
  Future<void> delete(String id);
  Future<void> addTrack(String playlistId, SearchResult track);

  /// Adiciona em lote; o servidor registra e baixa em segundo plano.
  Future<void> addTracks(String playlistId, List<SearchResult> tracks);
  Future<void> removeTrack(String playlistId, String trackId);
  Future<void> reorder(String playlistId, List<String> trackIds);
  Future<void> uploadCover(
    String playlistId,
    List<int> bytes, {
    required String filename,
    required String mimeType,
  });
  Future<List<Person>> directory();
  Future<void> setMember(String playlistId, String userId, PlaylistRole role);
  Future<void> removeMember(String playlistId, String userId);
}

class HttpPlaylistRepository implements PlaylistRepository {
  HttpPlaylistRepository(this._dio);

  final Dio _dio;

  @override
  Future<List<ServerPlaylist>> myPlaylists() => _call(() async {
    final r = await _dio.get<List<dynamic>>('/api/me/playlists');
    return [
      for (final p in r.data ?? const [])
        ServerPlaylist.fromJson(p as Map<String, dynamic>),
    ];
  });

  @override
  Future<PlaylistDetail> detail(String id) => _call(() async {
    final r = await _dio.get<Map<String, dynamic>>('/api/playlists/$id');
    return PlaylistDetail.fromJson(r.data!);
  });

  @override
  Future<ServerPlaylist> create(String name) => _call(() async {
    final r = await _dio.post<Map<String, dynamic>>(
      '/api/playlists',
      data: {'name': name},
    );
    return ServerPlaylist.fromJson(r.data!);
  });

  @override
  Future<void> rename(String id, String name) =>
      _call(() => _dio.patch<void>('/api/playlists/$id', data: {'name': name}));

  @override
  Future<void> delete(String id) =>
      _call(() => _dio.delete<void>('/api/playlists/$id'));

  @override
  Future<void> addTrack(String playlistId, SearchResult track) => _call(
    () => _dio.post<void>(
      '/api/playlists/$playlistId/tracks',
      data: track.toJson(),
    ),
  );

  @override
  Future<void> addTracks(String playlistId, List<SearchResult> tracks) => _call(
    () => _dio.post<void>(
      '/api/playlists/$playlistId/tracks/bulk',
      data: {
        'tracks': [for (final t in tracks) t.toJson()],
      },
    ),
  );

  @override
  Future<void> removeTrack(String playlistId, String trackId) => _call(
    () => _dio.delete<void>('/api/playlists/$playlistId/tracks/$trackId'),
  );

  @override
  Future<void> reorder(String playlistId, List<String> trackIds) => _call(
    () => _dio.put<void>(
      '/api/playlists/$playlistId/order',
      data: {'track_ids': trackIds},
    ),
  );

  @override
  Future<void> uploadCover(
    String playlistId,
    List<int> bytes, {
    required String filename,
    required String mimeType,
  }) => _call(
    () => _dio.put<void>(
      '/api/playlists/$playlistId/cover',
      data: FormData.fromMap({
        'file': MultipartFile.fromBytes(
          bytes,
          filename: filename,
          contentType: DioMediaType.parse(mimeType),
        ),
      }),
    ),
  );

  @override
  Future<List<Person>> directory() => _call(() async {
    final r = await _dio.get<List<dynamic>>('/api/users/directory');
    return [
      for (final p in r.data ?? const [])
        Person.fromJson(p as Map<String, dynamic>),
    ];
  });

  @override
  Future<void> setMember(String playlistId, String userId, PlaylistRole role) =>
      _call(
        () => _dio.put<void>(
          '/api/playlists/$playlistId/members/$userId',
          data: {'role': role.name},
        ),
      );

  @override
  Future<void> removeMember(String playlistId, String userId) => _call(
    () => _dio.delete<void>('/api/playlists/$playlistId/members/$userId'),
  );

  static Future<T> _call<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }
}

/// Playlists em memória (testes). [role] define o papel do usuário em todas.
class FakePlaylistRepository implements PlaylistRepository {
  FakePlaylistRepository({this.role = PlaylistRole.owner});

  PlaylistRole role;
  static const me = Person(id: 'u1', username: 'demo', name: 'Demo');
  static const ana = Person(id: 'u2', username: 'ana', name: 'Ana');
  static const pedro = Person(id: 'u3', username: 'pedro', name: 'Pedro');

  final playlists = <ServerPlaylist>[
    const ServerPlaylist(id: 'p1', name: 'Roadtrip'),
  ];
  final added = <String, List<String>>{};
  final members = <String, Map<String, PlaylistRole>>{};
  final reorders = <List<String>>[];
  final removed = <String>[];
  int coverUploads = 0;

  /// Faixas da playlist p1 (como no protótipo, com quem adicionou).
  final tracks = <PlaylistTrack>[
    for (final (i, (title, artist, by, secs)) in [
      ('Blinding Lights', 'The Weeknd', me, 200),
      ('Levitating', 'Dua Lipa', ana, 203),
      ('Get Lucky', 'Daft Punk', pedro, 369),
      ('Redbone', 'Childish Gambino', me, 327),
      ('Smells Like Teen Spirit', 'Nirvana', ana, 301),
    ].indexed)
      PlaylistTrack(
        trackId: 'tr$i',
        provider: 'spotify',
        externalId: 'sp$i',
        title: title,
        artist: artist,
        durationSeconds: secs,
        addedBy: by,
        addedAt: '2026-10-0${i + 1}T10:00:00Z',
        position: i + 1,
        ready: i.isEven,
        sizeBytes: 4000000,
      ),
  ];

  @override
  Future<List<ServerPlaylist>> myPlaylists() async => [
    for (final p in playlists)
      ServerPlaylist(
        id: p.id,
        name: p.name,
        role: role.name,
        trackCount: p.id == 'p1' ? tracks.length : 0,
        peopleCount: 1 + (members[p.id]?.length ?? 0),
      ),
  ];

  @override
  Future<PlaylistDetail> detail(String id) async {
    final p = playlists.firstWhere((p) => p.id == id);
    return PlaylistDetail(
      id: id,
      name: p.name,
      owner: me,
      role: role.name,
      members: [
        const PlaylistMember(user: ana, role: 'editor'),
        const PlaylistMember(user: pedro, role: 'viewer'),
      ],
      tracks: id == 'p1' ? List.of(tracks) : const [],
    );
  }

  @override
  Future<ServerPlaylist> create(String name) async {
    final p = ServerPlaylist(id: 'p${playlists.length + 1}', name: name);
    playlists.add(p);
    return p;
  }

  @override
  Future<void> rename(String id, String name) async {
    final i = playlists.indexWhere((p) => p.id == id);
    playlists[i] = ServerPlaylist(id: id, name: name);
  }

  @override
  Future<void> delete(String id) async =>
      playlists.removeWhere((p) => p.id == id);

  @override
  Future<void> addTrack(String playlistId, SearchResult track) async =>
      (added[playlistId] ??= []).add(track.title);

  @override
  Future<void> addTracks(String playlistId, List<SearchResult> tracks) async =>
      (added[playlistId] ??= []).addAll(tracks.map((t) => t.title));

  @override
  Future<void> removeTrack(String playlistId, String trackId) async {
    removed.add(trackId);
    tracks.removeWhere((t) => t.trackId == trackId);
  }

  @override
  Future<void> reorder(String playlistId, List<String> trackIds) async {
    reorders.add(trackIds);
    tracks.sort(
      (a, b) =>
          trackIds.indexOf(a.trackId).compareTo(trackIds.indexOf(b.trackId)),
    );
  }

  @override
  Future<void> uploadCover(
    String playlistId,
    List<int> bytes, {
    required String filename,
    required String mimeType,
  }) async => coverUploads++;

  @override
  Future<List<Person>> directory() async => const [me, ana, pedro];

  @override
  Future<void> setMember(
    String playlistId,
    String userId,
    PlaylistRole role,
  ) async => (members[playlistId] ??= {})[userId] = role;

  @override
  Future<void> removeMember(String playlistId, String userId) async =>
      members[playlistId]?.remove(userId);
}

final playlistRepositoryProvider = Provider<PlaylistRepository>(
  (ref) => HttpPlaylistRepository(ref.watch(apiDioProvider)),
);
