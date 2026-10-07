import '../../data/models/playlist_models.dart';
import '../../data/models/playlist_op.dart';

/// Aplica as alterações pendentes sobre a última cópia conhecida do servidor,
/// do mesmo jeito que o servidor vai aplicar (`backend/app/playlists/ops.py`).
/// Assim a tela mostra na hora o que a pessoa fez, com ou sem servidor.
///
/// Devolve nulo se a playlist foi apagada por uma das alterações.
PlaylistDetail? applyOpsToDetail(
  PlaylistDetail base,
  Iterable<PlaylistOp> ops, {
  Person? me,
  DateTime? now,
}) {
  var name = base.name;
  final tracks = [...base.tracks];
  for (final op in ops) {
    if (op.playlist != base.id) continue;
    switch (op.type) {
      case PlaylistOpType.create:
        break;
      case PlaylistOpType.rename:
        name = op.name ?? name;
      case PlaylistOpType.add:
        final t = op.track!;
        final exists = tracks.any(
          (x) => x.provider == t.provider && x.externalId == t.externalId,
        );
        if (!exists) {
          tracks.add(
            PlaylistTrack(
              trackId: op.ref!,
              provider: t.provider,
              externalId: t.externalId,
              title: t.title,
              artist: t.artist,
              album: t.album,
              durationSeconds: t.durationSeconds,
              isrc: t.isrc,
              coverUrl: t.coverUrl,
              addedBy: me,
              addedAt: (now ?? DateTime.now()).toUtc().toIso8601String(),
            ),
          );
        }
      case PlaylistOpType.remove:
        tracks.removeWhere((x) => x.trackId == op.trackId);
      case PlaylistOpType.move:
        final order = moveInOrder(
          [for (final t in tracks) t.trackId],
          op.trackId!,
          after: op.after,
          before: op.before,
        );
        final byId = {for (final t in tracks) t.trackId: t};
        tracks
          ..clear()
          ..addAll([for (final id in order) byId[id]!]);
      case PlaylistOpType.delete:
        return null;
    }
  }
  return PlaylistDetail(
    id: base.id,
    name: name,
    description: base.description,
    owner: base.owner,
    role: base.role,
    coverUrl: base.coverUrl,
    updatedAt: base.updatedAt,
    members: base.members,
    tracks: [
      for (final (i, t) in tracks.indexed)
        PlaylistTrack(
          trackId: t.trackId,
          provider: t.provider,
          externalId: t.externalId,
          title: t.title,
          artist: t.artist,
          album: t.album,
          durationSeconds: t.durationSeconds,
          isrc: t.isrc,
          coverUrl: t.coverUrl,
          addedBy: t.addedBy,
          addedAt: t.addedAt,
          position: i + 1,
          ready: t.ready,
          sizeBytes: t.sizeBytes,
        ),
    ],
  );
}

/// Playlist criada no aparelho que ainda não chegou ao servidor.
PlaylistDetail pendingPlaylist(PlaylistOp create, {Person? owner}) =>
    PlaylistDetail(id: create.playlist, name: create.name ?? '', owner: owner);

/// Lista da Biblioteca com as alterações pendentes.
List<ServerPlaylist> applyOpsToList(
  List<ServerPlaylist> base,
  Iterable<PlaylistOp> ops, {
  Person? me,
}) {
  final list = [...base];
  int find(String id) => list.indexWhere((p) => p.id == id);
  ServerPlaylist copy(ServerPlaylist p, {String? name, int? trackCount}) =>
      ServerPlaylist(
        id: p.id,
        name: name ?? p.name,
        description: p.description,
        owner: p.owner,
        role: p.role,
        trackCount: trackCount ?? p.trackCount,
        durationSeconds: p.durationSeconds,
        peopleCount: p.peopleCount,
        coverUrl: p.coverUrl,
        updatedAt: p.updatedAt,
      );
  for (final op in ops) {
    final i = find(op.playlist);
    switch (op.type) {
      case PlaylistOpType.create:
        if (i < 0) {
          list.insert(
            0,
            ServerPlaylist(id: op.playlist, name: op.name ?? '', owner: me),
          );
        }
      case PlaylistOpType.rename when i >= 0:
        list[i] = copy(list[i], name: op.name);
      case PlaylistOpType.add when i >= 0:
        list[i] = copy(list[i], trackCount: list[i].trackCount + 1);
      case PlaylistOpType.remove when i >= 0 && list[i].trackCount > 0:
        list[i] = copy(list[i], trackCount: list[i].trackCount - 1);
      case PlaylistOpType.delete when i >= 0:
        list.removeAt(i);
      default:
        break;
    }
  }
  return list;
}

/// Move [track] na lista de ids como o servidor faz: depois de [after]
/// (nulo = topo); se [after] sumiu, antes de [before]; se as duas sumiram,
/// fica onde está.
List<String> moveInOrder(
  List<String> order,
  String track, {
  String? after,
  String? before,
}) {
  final result = [...order];
  final original = result.indexOf(track);
  if (original < 0) return result;
  result.removeAt(original);
  final int index;
  if (after == null) {
    index = 0;
  } else if (result.contains(after)) {
    index = result.indexOf(after) + 1;
  } else if (before != null && result.contains(before)) {
    index = result.indexOf(before);
  } else {
    index = original;
  }
  result.insert(index, track);
  return result;
}

/// Operações "mover" que levam de [from] a [to] (mesmas faixas em outra
/// ordem). Só as faixas que realmente mudaram de lugar se movem: as que
/// formam a maior sequência já em ordem ficam paradas. Cada movimento usa
/// as vizinhas na ordem final como âncoras, o que também funciona se a
/// lista mudou no servidor nesse meio-tempo.
List<({String track, String? after, String? before})> movesFor(
  List<String> from,
  List<String> to,
) {
  final position = {for (final (i, id) in from.indexed) id: i};
  final common = [
    for (final id in to)
      if (position.containsKey(id)) id,
  ];
  final keep = _longestIncreasing(common, (id) => position[id]!);
  return [
    for (final (i, id) in common.indexed)
      if (!keep.contains(id))
        (
          track: id,
          after: i == 0 ? null : common[i - 1],
          before: i + 1 < common.length ? common[i + 1] : null,
        ),
  ];
}

/// Maior subsequência com [key] crescente (O(n log n)).
Set<String> _longestIncreasing(List<String> items, int Function(String) key) {
  final tails = <int>[]; // índice em items do fim de cada tamanho
  final previous = List<int>.filled(items.length, -1);
  for (var i = 0; i < items.length; i++) {
    var lo = 0;
    var hi = tails.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (key(items[tails[mid]]) < key(items[i])) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    if (lo > 0) previous[i] = tails[lo - 1];
    if (lo == tails.length) {
      tails.add(i);
    } else {
      tails[lo] = i;
    }
  }
  final result = <String>{};
  for (var i = tails.isEmpty ? -1 : tails.last; i >= 0; i = previous[i]) {
    result.add(items[i]);
  }
  return result;
}
