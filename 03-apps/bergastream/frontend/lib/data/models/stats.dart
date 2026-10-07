import 'package:json_annotation/json_annotation.dart';

import 'search_result.dart';

part 'stats.g.dart';

@JsonSerializable(fieldRename: FieldRename.snake)
class StatArtist {
  const StatArtist({required this.name, required this.plays, this.imageUrl});

  factory StatArtist.fromJson(Map<String, dynamic> json) =>
      _$StatArtistFromJson(json);

  final String name;
  final int plays;
  final String? imageUrl;

  Map<String, dynamic> toJson() => _$StatArtistToJson(this);
}

@JsonSerializable(fieldRename: FieldRename.snake)
class StatAlbum {
  const StatAlbum({
    required this.title,
    required this.artist,
    required this.plays,
    this.coverUrl,
  });

  factory StatAlbum.fromJson(Map<String, dynamic> json) =>
      _$StatAlbumFromJson(json);

  final String title;
  final String artist;
  final int plays;
  final String? coverUrl;

  Map<String, dynamic> toJson() => _$StatAlbumToJson(this);
}

/// Faixa mais tocada: os campos da faixa + `plays` (JSON manual).
class StatTrack {
  const StatTrack({required this.track, required this.plays});

  factory StatTrack.fromJson(Map<String, dynamic> json) => StatTrack(
    track: SearchResult.fromJson(json),
    plays: json['plays'] as int,
  );

  final SearchResult track;
  final int plays;

  Map<String, dynamic> toJson() => {...track.toJson(), 'plays': plays};
}

/// Métricas do mês (`GET /api/me/stats`).
@JsonSerializable(fieldRename: FieldRename.snake, explicitToJson: true)
class ListeningStats {
  const ListeningStats({
    required this.month,
    this.secondsMonth = 0,
    this.distinctTracksMonth = 0,
    this.playsMonth = 0,
    this.topArtists = const [],
    this.topTracks = const [],
    this.topAlbums = const [],
  });

  factory ListeningStats.fromJson(Map<String, dynamic> json) =>
      _$ListeningStatsFromJson(json);

  final String month;
  final int secondsMonth;
  final int distinctTracksMonth;
  final int playsMonth;
  final List<StatArtist> topArtists;
  @JsonKey(fromJson: _tracksFromJson)
  final List<StatTrack> topTracks;
  final List<StatAlbum> topAlbums;

  bool get isEmpty => playsMonth == 0;

  Map<String, dynamic> toJson() => _$ListeningStatsToJson(this);

  static List<StatTrack> _tracksFromJson(List<dynamic> list) => [
    for (final t in list) StatTrack.fromJson(t as Map<String, dynamic>),
  ];
}
