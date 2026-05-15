import 'track.dart';

class PlaylistCollaborator {
  final String userId;
  final String username;
  final String email;
  final DateTime addedAt;

  const PlaylistCollaborator({
    required this.userId,
    required this.username,
    required this.email,
    required this.addedAt,
  });

  factory PlaylistCollaborator.fromJson(Map<String, dynamic> json) =>
      PlaylistCollaborator(
        userId: json['user_id'] as String,
        username: json['username'] as String,
        email: json['email'] as String,
        addedAt: DateTime.parse(json['added_at'] as String),
      );
}

class Playlist {
  final String id;
  final String name;
  final String? description;
  final String? coverUrl;
  final bool isPublic;
  final bool isShared;
  final String? shareToken;
  final String ownerId;
  final int trackCount;
  final List<PlaylistTrack> tracks;
  final List<PlaylistCollaborator> collaborators;
  /// true when the current user is a collaborator (not the owner).
  final bool isCollaborative;

  const Playlist({
    required this.id,
    required this.name,
    this.description,
    this.coverUrl,
    this.isPublic = false,
    this.isShared = false,
    this.shareToken,
    required this.ownerId,
    this.trackCount = 0,
    this.tracks = const [],
    this.collaborators = const [],
    this.isCollaborative = false,
  });

  factory Playlist.fromJson(Map<String, dynamic> json) => Playlist(
    id: json['id'] as String,
    name: json['name'] as String,
    description: json['description'] as String?,
    coverUrl: json['cover_url'] as String?,
    isPublic: json['is_public'] as bool? ?? false,
    isShared: json['is_shared'] as bool? ?? false,
    shareToken: json['share_token'] as String?,
    ownerId: json['owner_id'] as String,
    trackCount: json['track_count'] as int? ?? 0,
    tracks: (json['tracks'] as List<dynamic>?)
            ?.map((t) => PlaylistTrack.fromJson(t as Map<String, dynamic>))
            .toList() ??
        [],
    collaborators: (json['collaborators'] as List<dynamic>?)
            ?.map((c) => PlaylistCollaborator.fromJson(c as Map<String, dynamic>))
            .toList() ??
        [],
    isCollaborative: json['is_collaborative'] as bool? ?? false,
  );
}

class PlaylistTrack {
  final String id;
  final Track track;
  final int position;

  const PlaylistTrack({required this.id, required this.track, required this.position});

  factory PlaylistTrack.fromJson(Map<String, dynamic> json) => PlaylistTrack(
    id: json['id'] as String,
    track: Track.fromJson(json['track'] as Map<String, dynamic>),
    position: json['position'] as int,
  );
}
