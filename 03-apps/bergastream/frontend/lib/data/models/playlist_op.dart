import 'dart:math';

import 'search_result.dart';

/// Alteração de playlist como *intenção* (`POST /api/playlists/ops`).
///
/// Feita no aparelho, entra numa fila e vai para o servidor na ordem. Como
/// descreve o que a pessoa quis ("adicionar X", "mover Y para depois de Z"),
/// e não o estado final, combina com o que mudou no servidor enquanto o
/// aparelho estava offline (ver `backend/app/playlists/ops.py`).
enum PlaylistOpType { create, rename, add, remove, move, delete, cover }

class PlaylistOp {
  const PlaylistOp._({
    required this.opId,
    required this.type,
    required this.playlist,
    this.ref,
    this.name,
    this.description,
    this.url,
    this.base,
    this.track,
    this.trackId,
    this.after,
    this.before,
    this.baseUpdatedAt,
    this.force = false,
  });

  /// Nova playlist; até existir no servidor ela é conhecida por [ref].
  factory PlaylistOp.create({
    required String ref,
    required String name,
    String? description,
  }) => PlaylistOp._(
    opId: newOpId(),
    type: PlaylistOpType.create,
    playlist: ref,
    ref: ref,
    name: name,
    description: description,
  );

  /// Capa a partir da imagem da playlist original ([url] de Spotify,
  /// Deezer ou YouTube; o servidor baixa).
  factory PlaylistOp.cover(String playlist, String url) => PlaylistOp._(
    opId: newOpId(),
    type: PlaylistOpType.cover,
    playlist: playlist,
    url: url,
  );

  /// [base]: nome que o aparelho conhecia (detecta conflito).
  factory PlaylistOp.rename(
    String playlist, {
    required String name,
    String? base,
    bool force = false,
  }) => PlaylistOp._(
    opId: newOpId(),
    type: PlaylistOpType.rename,
    playlist: playlist,
    name: name,
    base: base,
    force: force,
  );

  /// [ref]: id temporário da faixa até o servidor devolver o dela.
  factory PlaylistOp.add(String playlist, SearchResult track) => PlaylistOp._(
    opId: newOpId(),
    type: PlaylistOpType.add,
    playlist: playlist,
    track: track,
    ref: newRef(),
  );

  factory PlaylistOp.remove(String playlist, String trackId) => PlaylistOp._(
    opId: newOpId(),
    type: PlaylistOpType.remove,
    playlist: playlist,
    trackId: trackId,
  );

  /// Coloca [trackId] logo depois de [after] (nulo = no topo); [before] é a
  /// vizinha de reserva, se [after] tiver saído da playlist.
  factory PlaylistOp.move(
    String playlist,
    String trackId, {
    String? after,
    String? before,
  }) => PlaylistOp._(
    opId: newOpId(),
    type: PlaylistOpType.move,
    playlist: playlist,
    trackId: trackId,
    after: after,
    before: before,
  );

  /// [baseUpdatedAt]: `updated_at` que o aparelho conhecia; se a playlist
  /// mudou depois disso, o servidor não apaga (a não ser com [force]).
  factory PlaylistOp.delete(
    String playlist, {
    String? baseUpdatedAt,
    bool force = false,
  }) => PlaylistOp._(
    opId: newOpId(),
    type: PlaylistOpType.delete,
    playlist: playlist,
    baseUpdatedAt: baseUpdatedAt,
    force: force,
  );

  factory PlaylistOp.fromJson(Map<String, dynamic> json) {
    final type = PlaylistOpType.values.byName(json['type'] as String);
    final rawTrack = json['track'];
    return PlaylistOp._(
      opId: json['op_id'] as String,
      type: type,
      playlist: (json['playlist'] ?? json['ref']) as String,
      ref: json['ref'] as String?,
      name: json['name'] as String?,
      description: json['description'] as String?,
      url: json['url'] as String?,
      base: json['base'] as String?,
      track: rawTrack is Map<String, dynamic>
          ? SearchResult.fromJson(rawTrack)
          : null,
      trackId: rawTrack is String ? rawTrack : null,
      after: json['after'] as String?,
      before: json['before'] as String?,
      baseUpdatedAt: json['base_updated_at'] as String?,
      force: json['force'] as bool? ?? false,
    );
  }

  final String opId;
  final PlaylistOpType type;

  /// Id da playlist no servidor, ou o ref temporário dela.
  final String playlist;
  final String? ref;
  final String? name;
  final String? description;
  final String? url;
  final String? base;
  final SearchResult? track;
  final String? trackId;
  final String? after;
  final String? before;
  final String? baseUpdatedAt;
  final bool force;

  Map<String, dynamic> toJson() => {
    'op_id': opId,
    'type': type.name,
    if (type != PlaylistOpType.create) 'playlist': playlist,
    'ref': ?ref,
    'name': ?name,
    'description': ?description,
    'url': ?url,
    'base': ?base,
    if (track != null) 'track': track!.toJson(),
    if (trackId != null) 'track': trackId,
    // Em "move", after nulo significa "para o topo": vai explícito.
    if (type == PlaylistOpType.move) 'after': after,
    'before': ?before,
    'base_updated_at': ?baseUpdatedAt,
    if (force) 'force': true,
  };

  /// Troca refs temporários pelos ids que o servidor devolveu.
  PlaylistOp remap(Map<String, String> refs) {
    String? map(String? v) => v == null ? null : refs[v] ?? v;
    return PlaylistOp._(
      opId: opId,
      type: type,
      playlist: type == PlaylistOpType.create ? playlist : map(playlist)!,
      ref: ref,
      name: name,
      description: description,
      url: url,
      base: base,
      track: track,
      trackId: map(trackId),
      after: map(after),
      before: map(before),
      baseUpdatedAt: baseUpdatedAt,
      force: force,
    );
  }

  /// Prefixo dos ids temporários (o servidor reconhece o mesmo).
  static const refPrefix = 'tmp:';

  static bool isRef(String id) => id.startsWith(refPrefix);

  static String newRef() => '$refPrefix${newOpId()}';

  static final _random = Random.secure();

  /// UUID v4.
  static String newOpId() {
    final b = List<int>.generate(16, (_) => _random.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    String hex(int from, int to) => [
      for (var i = from; i < to; i++) b[i].toRadixString(16).padLeft(2, '0'),
    ].join();
    return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
  }
}

/// Resultado de cada operação no servidor.
enum OpStatus {
  applied,
  conflict,
  gone,
  forbidden,
  invalid,

  /// Falha passageira ou depende de algo ainda não enviado: fica na fila.
  retry;

  bool get isFinal => this != retry;
}

class OpResult {
  const OpResult({
    required this.opId,
    required this.status,
    this.playlistId,
    this.trackId,
    this.current,
    this.message,
  });

  factory OpResult.fromJson(Map<String, dynamic> json) => OpResult(
    opId: json['op_id'] as String,
    status: OpStatus.values.byName(json['status'] as String),
    playlistId: json['playlist_id'] as String?,
    trackId: json['track_id'] as String?,
    current: json['current'] as Map<String, dynamic>?,
    message: json['message'] as String?,
  );

  final String opId;
  final OpStatus status;
  final String? playlistId;
  final String? trackId;

  /// Conflito: o que está no servidor (ex.: `{"name": "..."}`).
  final Map<String, dynamic>? current;
  final String? message;
}

class OpBatchResult {
  const OpBatchResult({required this.results, this.refs = const {}});

  factory OpBatchResult.fromJson(Map<String, dynamic> json) => OpBatchResult(
    results: [
      for (final r in json['results'] as List<dynamic>)
        OpResult.fromJson(r as Map<String, dynamic>),
    ],
    refs: {
      for (final e in (json['refs'] as Map<String, dynamic>? ?? {}).entries)
        e.key: e.value as String,
    },
  );

  final List<OpResult> results;

  /// Ref temporário → id no servidor.
  final Map<String, String> refs;
}
