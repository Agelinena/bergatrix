import 'package:hive_flutter/hive_flutter.dart';

part 'track.g.dart';

@HiveType(typeId: 0)
class Track extends HiveObject {
  @HiveField(0) final String id;
  @HiveField(1) final String title;
  @HiveField(2) final String artist;
  @HiveField(3) final String? album;
  @HiveField(4) final String? albumId;
  @HiveField(5) final String? artistId;
  @HiveField(6) final int? durationMs;
  @HiveField(7) final int? year;
  @HiveField(8) final String? coverUrl;
  @HiveField(9) final String source;
  @HiveField(10) final String? sourceId;
  @HiveField(11) final bool isPermanent;
  @HiveField(12) final String? audioQuality;

  Track({
    required this.id,
    required this.title,
    required this.artist,
    this.album,
    this.albumId,
    this.artistId,
    this.durationMs,
    this.year,
    this.coverUrl,
    required this.source,
    this.sourceId,
    this.isPermanent = false,
    this.audioQuality,
  });

  factory Track.fromJson(Map<String, dynamic> json) => Track(
    id: json['id'] as String,
    title: json['title'] as String,
    artist: json['artist'] as String,
    album: json['album'] as String?,
    albumId: json['album_id'] as String?,
    artistId: json['artist_id'] as String?,
    durationMs: json['duration_ms'] as int?,
    year: json['year'] as int?,
    coverUrl: json['cover_url'] as String?,
    source: json['source'] as String,
    sourceId: json['source_id'] as String?,
    isPermanent: json['is_permanent'] as bool? ?? false,
    audioQuality: json['audio_quality'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'artist': artist,
    'album': album,
    'album_id': albumId,
    'artist_id': artistId,
    'duration_ms': durationMs,
    'year': year,
    'cover_url': coverUrl,
    'source': source,
    'source_id': sourceId,
    'is_permanent': isPermanent,
    'audio_quality': audioQuality,
  };

  String get durationFormatted {
    if (durationMs == null) return '--:--';
    final s = durationMs! ~/ 1000;
    final m = s ~/ 60;
    final sec = s % 60;
    return '$m:${sec.toString().padLeft(2, '0')}';
  }
}
