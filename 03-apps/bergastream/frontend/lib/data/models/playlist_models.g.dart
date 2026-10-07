// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'playlist_models.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

Person _$PersonFromJson(Map<String, dynamic> json) => Person(
  id: json['id'] as String,
  username: json['username'] as String,
  name: json['name'] as String,
);

Map<String, dynamic> _$PersonToJson(Person instance) => <String, dynamic>{
  'id': instance.id,
  'username': instance.username,
  'name': instance.name,
};

ServerPlaylist _$ServerPlaylistFromJson(Map<String, dynamic> json) =>
    ServerPlaylist(
      id: json['id'] as String,
      name: json['name'] as String,
      description: json['description'] as String? ?? '',
      owner: json['owner'] == null
          ? null
          : Person.fromJson(json['owner'] as Map<String, dynamic>),
      role: json['role'] as String? ?? 'owner',
      trackCount: (json['track_count'] as num?)?.toInt() ?? 0,
      durationSeconds: (json['duration_seconds'] as num?)?.toInt() ?? 0,
      peopleCount: (json['people_count'] as num?)?.toInt() ?? 1,
      coverUrl: json['cover_url'] as String?,
      updatedAt: json['updated_at'] as String?,
    );

PlaylistTrack _$PlaylistTrackFromJson(Map<String, dynamic> json) =>
    PlaylistTrack(
      trackId: json['track_id'] as String,
      provider: json['provider'] as String,
      externalId: json['external_id'] as String,
      title: json['title'] as String,
      artist: json['artist'] as String,
      album: json['album'] as String? ?? '',
      durationSeconds: (json['duration_seconds'] as num?)?.toInt() ?? 0,
      isrc: json['isrc'] as String?,
      coverUrl: json['cover_url'] as String?,
      addedBy: json['added_by'] == null
          ? null
          : Person.fromJson(json['added_by'] as Map<String, dynamic>),
      addedAt: json['added_at'] as String,
      position: (json['position'] as num?)?.toInt() ?? 0,
      ready: json['ready'] as bool? ?? false,
      sizeBytes: (json['size_bytes'] as num?)?.toInt(),
    );

PlaylistMember _$PlaylistMemberFromJson(Map<String, dynamic> json) =>
    PlaylistMember(
      user: Person.fromJson(json['user'] as Map<String, dynamic>),
      role: json['role'] as String,
    );

PlaylistDetail _$PlaylistDetailFromJson(Map<String, dynamic> json) =>
    PlaylistDetail(
      id: json['id'] as String,
      name: json['name'] as String,
      description: json['description'] as String? ?? '',
      owner: json['owner'] == null
          ? null
          : Person.fromJson(json['owner'] as Map<String, dynamic>),
      role: json['role'] as String? ?? 'owner',
      coverUrl: json['cover_url'] as String?,
      updatedAt: json['updated_at'] as String?,
      members:
          (json['members'] as List<dynamic>?)
              ?.map((e) => PlaylistMember.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
      tracks:
          (json['tracks'] as List<dynamic>?)
              ?.map((e) => PlaylistTrack.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
    );
