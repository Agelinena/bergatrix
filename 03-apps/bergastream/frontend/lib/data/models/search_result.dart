import 'package:json_annotation/json_annotation.dart';

part 'search_result.g.dart';

/// Item de `GET /api/search` (mesmos campos do `PlayRequest` do backend).
@JsonSerializable(fieldRename: FieldRename.snake)
class SearchResult {
  const SearchResult({
    required this.provider,
    required this.externalId,
    required this.title,
    required this.artist,
    this.album = '',
    this.durationSeconds = 0,
    this.isrc,
    this.coverUrl,
    this.artistId,
    this.albumId,
  });

  factory SearchResult.fromJson(Map<String, dynamic> json) =>
      _$SearchResultFromJson(json);

  /// `spotify`, `youtube` ou `ytmusic`.
  final String provider;
  final String externalId;
  final String title;
  final String artist;
  final String album;
  final int durationSeconds;
  final String? isrc;
  final String? coverUrl;

  /// Para "Ir para o artista/álbum" (quando a origem informa).
  final String? artistId;
  final String? albumId;

  /// Artista e álbum têm página no app (Spotify e YT Music).
  bool get hasCatalogPages => provider == 'spotify' || provider == 'ytmusic';

  /// Id estável para a UI (cor da capa, chaves de lista).
  String get id => '$provider:$externalId';

  Map<String, dynamic> toJson() => _$SearchResultToJson(this);
}
