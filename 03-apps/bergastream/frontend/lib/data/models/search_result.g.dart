// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'search_result.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

SearchResult _$SearchResultFromJson(Map<String, dynamic> json) => SearchResult(
  provider: json['provider'] as String,
  externalId: json['external_id'] as String,
  title: json['title'] as String,
  artist: json['artist'] as String,
  album: json['album'] as String? ?? '',
  durationSeconds: (json['duration_seconds'] as num?)?.toInt() ?? 0,
  isrc: json['isrc'] as String?,
  coverUrl: json['cover_url'] as String?,
  artistId: json['artist_id'] as String?,
  albumId: json['album_id'] as String?,
);

Map<String, dynamic> _$SearchResultToJson(SearchResult instance) =>
    <String, dynamic>{
      'provider': instance.provider,
      'external_id': instance.externalId,
      'title': instance.title,
      'artist': instance.artist,
      'album': instance.album,
      'duration_seconds': instance.durationSeconds,
      'isrc': instance.isrc,
      'cover_url': instance.coverUrl,
      'artist_id': instance.artistId,
      'album_id': instance.albumId,
    };
