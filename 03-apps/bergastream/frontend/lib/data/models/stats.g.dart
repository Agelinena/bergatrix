// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'stats.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

StatArtist _$StatArtistFromJson(Map<String, dynamic> json) => StatArtist(
  name: json['name'] as String,
  plays: (json['plays'] as num).toInt(),
  imageUrl: json['image_url'] as String?,
);

Map<String, dynamic> _$StatArtistToJson(StatArtist instance) =>
    <String, dynamic>{
      'name': instance.name,
      'plays': instance.plays,
      'image_url': instance.imageUrl,
    };

StatAlbum _$StatAlbumFromJson(Map<String, dynamic> json) => StatAlbum(
  title: json['title'] as String,
  artist: json['artist'] as String,
  plays: (json['plays'] as num).toInt(),
  coverUrl: json['cover_url'] as String?,
);

Map<String, dynamic> _$StatAlbumToJson(StatAlbum instance) => <String, dynamic>{
  'title': instance.title,
  'artist': instance.artist,
  'plays': instance.plays,
  'cover_url': instance.coverUrl,
};

ListeningStats _$ListeningStatsFromJson(Map<String, dynamic> json) =>
    ListeningStats(
      month: json['month'] as String,
      secondsMonth: (json['seconds_month'] as num?)?.toInt() ?? 0,
      distinctTracksMonth:
          (json['distinct_tracks_month'] as num?)?.toInt() ?? 0,
      playsMonth: (json['plays_month'] as num?)?.toInt() ?? 0,
      topArtists:
          (json['top_artists'] as List<dynamic>?)
              ?.map((e) => StatArtist.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
      topTracks: json['top_tracks'] == null
          ? const []
          : ListeningStats._tracksFromJson(json['top_tracks'] as List),
      topAlbums:
          (json['top_albums'] as List<dynamic>?)
              ?.map((e) => StatAlbum.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
    );

Map<String, dynamic> _$ListeningStatsToJson(ListeningStats instance) =>
    <String, dynamic>{
      'month': instance.month,
      'seconds_month': instance.secondsMonth,
      'distinct_tracks_month': instance.distinctTracksMonth,
      'plays_month': instance.playsMonth,
      'top_artists': instance.topArtists.map((e) => e.toJson()).toList(),
      'top_tracks': instance.topTracks.map((e) => e.toJson()).toList(),
      'top_albums': instance.topAlbums.map((e) => e.toJson()).toList(),
    };
