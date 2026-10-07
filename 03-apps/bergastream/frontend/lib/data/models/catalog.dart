import 'package:json_annotation/json_annotation.dart';

import 'search_full.dart';
import 'search_result.dart';

part 'catalog.g.dart';

/// Página do artista (`GET /api/artists/{provider}/{id}`).
@JsonSerializable(fieldRename: FieldRename.snake, createToJson: false)
class ArtistPage {
  const ArtistPage({
    required this.provider,
    required this.externalId,
    required this.name,
    this.imageUrl,
    this.followers,
    this.followersText,
    this.topTracks = const [],
    this.albums = const [],
  });

  factory ArtistPage.fromJson(Map<String, dynamic> json) =>
      _$ArtistPageFromJson(json);

  final String provider;
  final String externalId;
  final String name;
  final String? imageUrl;
  final int? followers;
  final String? followersText;
  final List<SearchResult> topTracks;
  final List<SearchAlbum> albums;
}

/// Uma página de "Todas as músicas" (paginação por offset).
@JsonSerializable(fieldRename: FieldRename.snake, createToJson: false)
class TrackPage {
  const TrackPage({
    this.items = const [],
    required this.offset,
    required this.total,
    this.nextOffset,
  });

  factory TrackPage.fromJson(Map<String, dynamic> json) =>
      _$TrackPageFromJson(json);

  final List<SearchResult> items;
  final int offset;
  final int total;
  final int? nextOffset;
}

/// Página do álbum (`GET /api/albums/{provider}/{id}`).
@JsonSerializable(fieldRename: FieldRename.snake, createToJson: false)
class AlbumPage {
  const AlbumPage({
    required this.provider,
    required this.externalId,
    required this.title,
    this.artist = '',
    this.artistId,
    this.year,
    this.imageUrl,
    this.tracks = const [],
  });

  factory AlbumPage.fromJson(Map<String, dynamic> json) =>
      _$AlbumPageFromJson(json);

  final String provider;
  final String externalId;
  final String title;
  final String artist;
  final String? artistId;
  final String? year;
  final String? imageUrl;
  final List<SearchResult> tracks;
}
