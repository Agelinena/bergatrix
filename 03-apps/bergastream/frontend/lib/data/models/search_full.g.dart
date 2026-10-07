// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'search_full.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

SearchArtist _$SearchArtistFromJson(Map<String, dynamic> json) => SearchArtist(
  provider: json['provider'] as String,
  externalId: json['external_id'] as String,
  name: json['name'] as String,
  imageUrl: json['image_url'] as String?,
);

Map<String, dynamic> _$SearchArtistToJson(SearchArtist instance) =>
    <String, dynamic>{
      'provider': instance.provider,
      'external_id': instance.externalId,
      'name': instance.name,
      'image_url': instance.imageUrl,
    };

SearchAlbum _$SearchAlbumFromJson(Map<String, dynamic> json) => SearchAlbum(
  provider: json['provider'] as String,
  externalId: json['external_id'] as String,
  title: json['title'] as String,
  artist: json['artist'] as String? ?? '',
  year: json['year'] as String?,
  imageUrl: json['image_url'] as String?,
);

Map<String, dynamic> _$SearchAlbumToJson(SearchAlbum instance) =>
    <String, dynamic>{
      'provider': instance.provider,
      'external_id': instance.externalId,
      'title': instance.title,
      'artist': instance.artist,
      'year': instance.year,
      'image_url': instance.imageUrl,
    };

FullSearchResult _$FullSearchResultFromJson(Map<String, dynamic> json) =>
    FullSearchResult(
      tracks:
          (json['tracks'] as List<dynamic>?)
              ?.map((e) => SearchResult.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
      artists:
          (json['artists'] as List<dynamic>?)
              ?.map((e) => SearchArtist.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
      albums:
          (json['albums'] as List<dynamic>?)
              ?.map((e) => SearchAlbum.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
    );

ResolvedLink _$ResolvedLinkFromJson(Map<String, dynamic> json) => ResolvedLink(
  source: json['source'] as String,
  kind: json['kind'] as String,
  title: json['title'] as String,
  subtitle: json['subtitle'] as String? ?? '',
  coverUrl: json['cover_url'] as String?,
  total: (json['total'] as num?)?.toInt() ?? 0,
  tracks:
      (json['tracks'] as List<dynamic>?)
          ?.map((e) => SearchResult.fromJson(e as Map<String, dynamic>))
          .toList() ??
      const [],
  externalUrl: json['external_url'] as String,
);
