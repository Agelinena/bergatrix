import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_error.dart';
import '../api/api_dio.dart';
import '../../features/playlists/playlist_merge.dart';
import '../models/playlist_models.dart';
import '../models/playlist_op.dart';
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

  /// Alterações em lote, na ordem (`POST /api/playlists/ops`).
  Future<OpBatchResult> applyOps(List<PlaylistOp> ops);
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
      // Playlist inteira num envio só (até 10.000 faixas, alguns MB).
      options: Options(sendTimeout: const Duration(minutes: 2)),
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

  @override
  Future<OpBatchResult> applyOps(List<PlaylistOp> ops) => _call(() async {
    final r = await _dio.post<Map<String, dynamic>>(
      '/api/playlists/ops',
      data: {
        'ops': [for (final op in ops) op.toJson()],
      },
    );
    return OpBatchResult.fromJson(r.data!);
  });

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

  /// Lotes recebidos em [applyOps] (na ordem).
  final batches = <List<PlaylistOp>>[];

  /// Substitui as regras do servidor num teste (ex.: forçar conflito).
  OpBatchResult Function(List<PlaylistOp> ops)? opsHandler;

  /// Simula servidor fora do ar em [applyOps].
  bool offline = false;
  final members = <String, Map<String, PlaylistRole>>{};
  final reorders = <List<String>>[];
  final removed = <String>[];
  int coverUploads = 0;

  /// Descrição e capa (URL da origem) por playlist.
  final descriptions = <String, String>{};
  final covers = <String, String>{};

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

  /// Faixas de cada playlist (p1 = [tracks]).
  late final trackLists = <String, List<PlaylistTrack>>{'p1': tracks};

  @override
  Future<List<ServerPlaylist>> myPlaylists() async => [
    for (final p in playlists)
      ServerPlaylist(
        id: p.id,
        name: p.name,
        role: role.name,
        trackCount: trackLists[p.id]?.length ?? 0,
        peopleCount: 1 + (members[p.id]?.length ?? 0),
        description: descriptions[p.id] ?? '',
        coverUrl: covers[p.id],
        updatedAt: p.updatedAt,
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
      description: descriptions[id] ?? '',
      coverUrl: covers[id],
      updatedAt: p.updatedAt,
      members: [
        const PlaylistMember(user: ana, role: 'editor'),
        const PlaylistMember(user: pedro, role: 'viewer'),
      ],
      tracks: List.of(trackLists[id] ?? const <PlaylistTrack>[]),
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
    playlists[i] = ServerPlaylist(
      id: id,
      name: name,
      updatedAt: playlists[i].updatedAt,
    );
  }

  @override
  Future<void> delete(String id) async {
    playlists.removeWhere((p) => p.id == id);
    trackLists.remove(id);
  }

  @override
  Future<void> addTrack(String playlistId, SearchResult track) async =>
      (added[playlistId] ??= []).add(track.title);

  @override
  Future<void> addTracks(String playlistId, List<SearchResult> tracks) async =>
      (added[playlistId] ??= []).addAll(tracks.map((t) => t.title));

  @override
  Future<void> removeTrack(String playlistId, String trackId) async {
    removed.add(trackId);
    trackLists[playlistId]?.removeWhere((t) => t.trackId == trackId);
  }

  @override
  Future<void> reorder(String playlistId, List<String> trackIds) async {
    reorders.add(trackIds);
    trackLists[playlistId]?.sort(
      (a, b) =>
          trackIds.indexOf(a.trackId).compareTo(trackIds.indexOf(b.trackId)),
    );
  }

  /// Mesmas regras do servidor (`backend/app/playlists/ops.py`).
  @override
  Future<OpBatchResult> applyOps(List<PlaylistOp> ops) async {
    if (offline) {
      throw const ApiException(ApiErrorKind.semConexao);
    }
    batches.add(ops);
    if (opsHandler case final handler?) return handler(ops);
    final refs = <String, String>{};
    final results = <OpResult>[];
    String map(String id) => refs[id] ?? id;
    for (final op in ops) {
      OpResult result(
        OpStatus status, {
        String? id,
        Map<String, dynamic>? current,
        String? trackId,
      }) => OpResult(
        opId: op.opId,
        status: status,
        playlistId: id,
        current: current,
        trackId: trackId,
      );
      final pending = [op.playlist, op.trackId, op.after, op.before]
          .whereType<String>()
          .where(
            (v) =>
                op.type != PlaylistOpType.create &&
                PlaylistOp.isRef(v) &&
                !refs.containsKey(v),
          );
      if (pending.isNotEmpty) {
        results.add(result(OpStatus.retry));
        continue;
      }
      if (op.type == PlaylistOpType.create) {
        final p = await create(op.name!);
        if (op.description case final d? when d.isNotEmpty) {
          descriptions[p.id] = d;
        }
        refs[op.ref!] = p.id;
        trackLists[p.id] = [];
        results.add(result(OpStatus.applied, id: p.id));
        continue;
      }
      final id = map(op.playlist);
      final i = playlists.indexWhere((p) => p.id == id);
      if (i < 0) {
        results.add(result(OpStatus.gone, id: id));
        continue;
      }
      final need = op.type == PlaylistOpType.delete
          ? PlaylistRole.owner
          : PlaylistRole.editor;
      if (role.index > need.index) {
        results.add(result(OpStatus.forbidden, id: id));
        continue;
      }
      final current = playlists[i];
      switch (op.type) {
        case PlaylistOpType.rename:
          if (current.name != op.name &&
              !op.force &&
              op.base != null &&
              current.name != op.base) {
            results.add(
              result(
                OpStatus.conflict,
                id: id,
                current: {'name': current.name},
              ),
            );
            continue;
          }
          await rename(id, op.name!);
        case PlaylistOpType.add:
          final t = op.track!;
          final trackId = 'srv-${t.externalId}';
          refs[op.ref!] = trackId;
          await addTrack(id, t);
          final list = trackLists[id] ??= [];
          if (!list.any((x) => x.trackId == trackId)) {
            list.add(
              PlaylistTrack(
                trackId: trackId,
                provider: t.provider,
                externalId: t.externalId,
                title: t.title,
                artist: t.artist,
                addedBy: me,
                addedAt: '2026-10-07T12:00:00Z',
                position: list.length + 1,
              ),
            );
          }
          results.add(result(OpStatus.applied, id: id, trackId: trackId));
          continue;
        case PlaylistOpType.remove:
          await removeTrack(id, map(op.trackId!));
        case PlaylistOpType.move:
          final order = [
            for (final t in trackLists[id] ?? const <PlaylistTrack>[])
              t.trackId,
          ];
          final moved = moveInOrder(
            order,
            map(op.trackId!),
            after: op.after == null ? null : map(op.after!),
            before: op.before == null ? null : map(op.before!),
          );
          await reorder(id, moved);
        case PlaylistOpType.delete:
          if (!op.force &&
              op.baseUpdatedAt != null &&
              current.updatedAt != null &&
              current.updatedAt != op.baseUpdatedAt) {
            results.add(
              result(
                OpStatus.conflict,
                id: id,
                current: {'name': current.name},
              ),
            );
            continue;
          }
          await delete(id);
        case PlaylistOpType.cover:
          covers[id] = op.url!;
        case PlaylistOpType.create:
          break;
      }
      results.add(result(OpStatus.applied, id: id));
    }
    return OpBatchResult(results: results, refs: refs);
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
