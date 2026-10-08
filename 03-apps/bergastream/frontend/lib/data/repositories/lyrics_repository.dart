import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_error.dart';
import '../api/api_dio.dart';
import '../models/search_result.dart';

/// Uma linha da letra sincronizada.
class LyricLine {
  const LyricLine(this.time, this.text);

  final Duration time;
  final String text;

  Map<String, dynamic> toJson() => {
    'time_ms': time.inMilliseconds,
    'text': text,
  };
}

/// Letra da faixa (`POST /api/lyrics`, fonte LRCLIB).
class Lyrics {
  const Lyrics({required this.found, this.synced = const [], this.plain});

  factory Lyrics.fromJson(Map<String, dynamic> json) => Lyrics(
    found: json['found'] as bool? ?? false,
    synced: [
      for (final l in json['synced'] as List<dynamic>? ?? const [])
        LyricLine(
          Duration(milliseconds: (l as Map<String, dynamic>)['time_ms'] as int),
          l['text'] as String? ?? '',
        ),
    ],
    plain: json['plain'] as String?,
  );

  static const none = Lyrics(found: false);

  final bool found;

  /// Linhas com tempo (acompanha a música). Vazia se só há texto.
  final List<LyricLine> synced;

  /// Texto sem tempo (quando não há sincronizada).
  final String? plain;

  bool get isSynced => synced.isNotEmpty;

  Map<String, dynamic> toJson() => {
    'found': found,
    'synced': [for (final l in synced) l.toJson()],
    'plain': plain,
  };
}

abstract interface class LyricsRepository {
  /// Lança [ApiException].
  Future<Lyrics> lyrics(SearchResult track);
}

class HttpLyricsRepository implements LyricsRepository {
  HttpLyricsRepository(this._dio);

  final Dio _dio;

  @override
  Future<Lyrics> lyrics(SearchResult track) async {
    try {
      final r = await _dio.post<Map<String, dynamic>>(
        '/api/lyrics',
        data: track.toJson(),
      );
      return Lyrics.fromJson(r.data!);
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }
}

/// Letra fixa (testes): três linhas a cada 10 s; "Instrumental" não tem.
class FakeLyricsRepository implements LyricsRepository {
  int calls = 0;

  static const sample = Lyrics(
    found: true,
    synced: [
      LyricLine(Duration(seconds: 5), 'Primeira linha da letra'),
      LyricLine(Duration(seconds: 15), 'Segunda linha da letra'),
      LyricLine(Duration(seconds: 25), 'Terceira linha da letra'),
    ],
  );

  @override
  Future<Lyrics> lyrics(SearchResult track) async {
    calls++;
    return track.title.contains('Instrumental') ? Lyrics.none : sample;
  }
}

final lyricsRepositoryProvider = Provider<LyricsRepository>(
  (ref) => HttpLyricsRepository(ref.watch(apiDioProvider)),
);
