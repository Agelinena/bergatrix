import 'package:json_annotation/json_annotation.dart';

import 'search_result.dart';

part 'search_full.g.dart';

/// Artista nos resultados (`GET /api/search/full`).
@JsonSerializable(fieldRename: FieldRename.snake)
class SearchArtist {
  const SearchArtist({
    required this.provider,
    required this.externalId,
    required this.name,
    this.imageUrl,
  });

  factory SearchArtist.fromJson(Map<String, dynamic> json) =>
      _$SearchArtistFromJson(json);

  final String provider;
  final String externalId;
  final String name;
  final String? imageUrl;

  String get id => '$provider:$externalId';

  Map<String, dynamic> toJson() => _$SearchArtistToJson(this);
}

/// Álbum nos resultados.
@JsonSerializable(fieldRename: FieldRename.snake)
class SearchAlbum {
  const SearchAlbum({
    required this.provider,
    required this.externalId,
    required this.title,
    this.artist = '',
    this.year,
    this.imageUrl,
  });

  factory SearchAlbum.fromJson(Map<String, dynamic> json) =>
      _$SearchAlbumFromJson(json);

  final String provider;
  final String externalId;
  final String title;
  final String artist;
  final String? year;
  final String? imageUrl;

  String get id => '$provider:$externalId';

  Map<String, dynamic> toJson() => _$SearchAlbumToJson(this);
}

/// Resposta de `GET /api/search/full`.
@JsonSerializable(fieldRename: FieldRename.snake, createToJson: false)
class FullSearchResult {
  const FullSearchResult({
    this.tracks = const [],
    this.artists = const [],
    this.albums = const [],
  });

  factory FullSearchResult.fromJson(Map<String, dynamic> json) =>
      _$FullSearchResultFromJson(json);

  final List<SearchResult> tracks;
  final List<SearchArtist> artists;
  final List<SearchAlbum> albums;

  bool get isEmpty => tracks.isEmpty && artists.isEmpty && albums.isEmpty;
}

/// Link resolvido (`GET /api/resolve`): faixa, álbum ou playlist.
@JsonSerializable(fieldRename: FieldRename.snake, createToJson: false)
class ResolvedLink {
  const ResolvedLink({
    required this.source,
    required this.kind,
    required this.title,
    this.subtitle = '',
    this.coverUrl,
    this.description = '',
    this.total = 0,
    this.tracks = const [],
    required this.externalUrl,
  });

  factory ResolvedLink.fromJson(Map<String, dynamic> json) =>
      _$ResolvedLinkFromJson(json);

  /// `spotify`, `deezer` ou `youtube`.
  final String source;

  /// `track`, `album` ou `playlist`.
  final String kind;
  final String title;
  final String subtitle;
  final String? coverUrl;

  /// Descrição da playlist original (vai junto em "Importar tudo").
  final String description;
  final int total;
  final List<SearchResult> tracks;
  final String externalUrl;

  bool get isTrack => kind == 'track';

  String get sourceLabel => switch (source) {
    'spotify' => 'Spotify',
    'deezer' => 'Deezer',
    _ => 'YouTube',
  };
}
