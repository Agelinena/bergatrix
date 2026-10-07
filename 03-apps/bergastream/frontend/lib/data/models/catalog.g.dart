// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'catalog.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

ArtistPage _$ArtistPageFromJson(Map<String, dynamic> json) => ArtistPage(
  provider: json['provider'] as String,
  externalId: json['external_id'] as String,
  name: json['name'] as String,
  imageUrl: json['image_url'] as String?,
  followers: (json['followers'] as num?)?.toInt(),
  followersText: json['followers_text'] as String?,
  topTracks:
      (json['top_tracks'] as List<dynamic>?)
          ?.map((e) => SearchResult.fromJson(e as Map<String, dynamic>))
          .toList() ??
      const [],
  albums:
      (json['albums'] as List<dynamic>?)
          ?.map((e) => SearchAlbum.fromJson(e as Map<String, dynamic>))
          .toList() ??
      const [],
);

TrackPage _$TrackPageFromJson(Map<String, dynamic> json) => TrackPage(
  items:
      (json['items'] as List<dynamic>?)
          ?.map((e) => SearchResult.fromJson(e as Map<String, dynamic>))
          .toList() ??
      const [],
  offset: (json['offset'] as num).toInt(),
  total: (json['total'] as num).toInt(),
  nextOffset: (json['next_offset'] as num?)?.toInt(),
);

AlbumPage _$AlbumPageFromJson(Map<String, dynamic> json) => AlbumPage(
  provider: json['provider'] as String,
  externalId: json['external_id'] as String,
  title: json['title'] as String,
  artist: json['artist'] as String? ?? '',
  artistId: json['artist_id'] as String?,
  year: json['year'] as String?,
  imageUrl: json['image_url'] as String?,
  tracks:
      (json['tracks'] as List<dynamic>?)
          ?.map((e) => SearchResult.fromJson(e as Map<String, dynamic>))
          .toList() ??
      const [],
);
