import 'package:json_annotation/json_annotation.dart';

import 'search_result.dart';

part 'playlist_models.g.dart';

/// Pessoa (dono, colaborador, quem adicionou).
@JsonSerializable(fieldRename: FieldRename.snake)
class Person {
  const Person({required this.id, required this.username, required this.name});

  factory Person.fromJson(Map<String, dynamic> json) => _$PersonFromJson(json);

  final String id;
  final String username;
  final String name;

  Map<String, dynamic> toJson() => _$PersonToJson(this);
}

/// Papel na playlist.
enum PlaylistRole {
  owner,
  editor,
  viewer;

  bool get canEdit => this != viewer;
  bool get isOwner => this == owner;

  static PlaylistRole parse(String? value) =>
      values.firstWhere((r) => r.name == value, orElse: () => viewer);
}

/// Playlist do servidor na lista da Biblioteca (`GET /api/me/playlists`).
@JsonSerializable(fieldRename: FieldRename.snake, explicitToJson: true)
class ServerPlaylist {
  const ServerPlaylist({
    required this.id,
    required this.name,
    this.description = '',
    this.owner,
    this.role = 'owner',
    this.trackCount = 0,
    this.durationSeconds = 0,
    this.peopleCount = 1,
    this.coverUrl,
    this.updatedAt,
  });

  factory ServerPlaylist.fromJson(Map<String, dynamic> json) =>
      _$ServerPlaylistFromJson(json);

  Map<String, dynamic> toJson() => _$ServerPlaylistToJson(this);

  final String id;
  final String name;
  final String description;
  final Person? owner;
  final String role;
  final int trackCount;
  final int durationSeconds;
  final int peopleCount;

  /// Relativa ao servidor (`/api/playlists/<id>/cover?v=...`).
  final String? coverUrl;
  final String? updatedAt;

  PlaylistRole get playlistRole => PlaylistRole.parse(role);
}

/// Faixa da playlist, com quem adicionou e se está pronta no servidor.
@JsonSerializable(fieldRename: FieldRename.snake, explicitToJson: true)
class PlaylistTrack {
  const PlaylistTrack({
    required this.trackId,
    required this.provider,
    required this.externalId,
    required this.title,
    required this.artist,
    this.album = '',
    this.durationSeconds = 0,
    this.isrc,
    this.coverUrl,
    this.addedBy,
    required this.addedAt,
    this.position = 0,
    this.ready = false,
    this.sizeBytes,
  });

  factory PlaylistTrack.fromJson(Map<String, dynamic> json) =>
      _$PlaylistTrackFromJson(json);

  Map<String, dynamic> toJson() => _$PlaylistTrackToJson(this);

  final String trackId;
  final String provider;
  final String externalId;
  final String title;
  final String artist;
  final String album;
  final int durationSeconds;
  final String? isrc;
  final String? coverUrl;
  final Person? addedBy;
  final String addedAt;
  final int position;
  final bool ready;
  final int? sizeBytes;

  /// Para o player e o menu ⋮.
  SearchResult get asResult => SearchResult(
    provider: provider,
    externalId: externalId,
    title: title,
    artist: artist,
    album: album,
    durationSeconds: durationSeconds,
    isrc: isrc,
    coverUrl: coverUrl,
  );
}

@JsonSerializable(fieldRename: FieldRename.snake, explicitToJson: true)
class PlaylistMember {
  const PlaylistMember({required this.user, required this.role});

  factory PlaylistMember.fromJson(Map<String, dynamic> json) =>
      _$PlaylistMemberFromJson(json);

  Map<String, dynamic> toJson() => _$PlaylistMemberToJson(this);

  final Person user;
  final String role;
}

/// Detalhe da playlist (`GET /api/playlists/{id}`).
@JsonSerializable(fieldRename: FieldRename.snake, explicitToJson: true)
class PlaylistDetail {
  const PlaylistDetail({
    required this.id,
    required this.name,
    this.description = '',
    this.owner,
    this.role = 'owner',
    this.coverUrl,
    this.updatedAt,
    this.members = const [],
    this.tracks = const [],
  });

  factory PlaylistDetail.fromJson(Map<String, dynamic> json) =>
      _$PlaylistDetailFromJson(json);

  Map<String, dynamic> toJson() => _$PlaylistDetailToJson(this);

  final String id;
  final String name;
  final String description;
  final Person? owner;
  final String role;
  final String? coverUrl;
  final String? updatedAt;
  final List<PlaylistMember> members;
  final List<PlaylistTrack> tracks;

  PlaylistRole get playlistRole => PlaylistRole.parse(role);
}
