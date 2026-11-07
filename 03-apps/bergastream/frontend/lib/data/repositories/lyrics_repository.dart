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
  const Lyrics({
    required this.found,
    this.synced = const [],
    this.plain,
    this.trackId,
    this.offsetMs = 0,
    this.lrc,
    this.edited = false,
  });

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
    trackId: json['track_id'] as String?,
    offsetMs: json['offset_ms'] as int? ?? 0,
    lrc: json['lrc'] as String?,
    edited: json['edited'] == true,
  );

  static const none = Lyrics(found: false);

  final bool found;

  /// Linhas com tempo (acompanha a música). Vazia se só há texto.
  final List<LyricLine> synced;

  /// Texto sem tempo (quando não há sincronizada).
  final String? plain;

  bool get isSynced => synced.isNotEmpty;

  /// Id da faixa no servidor (para corrigir a letra).
  final String? trackId;

  /// Atraso (+) ou adiantamento (−) já somado aos tempos de [synced].
  final int offsetMs;

  /// Texto LRC guardado (sem o ajuste), para o editor.
  final String? lrc;

  /// Alguém corrigiu à mão (pode "buscar de novo").
  final bool edited;

  /// Mesma letra com os tempos andando [deltaMs] (prévia do ajuste).
  Lyrics shifted(int deltaMs) => deltaMs == 0
      ? this
      : Lyrics(
          found: found,
          synced: [
            for (final l in synced)
              LyricLine(
                Duration(
                  milliseconds: (l.time.inMilliseconds + deltaMs) < 0
                      ? 0
                      : l.time.inMilliseconds + deltaMs,
                ),
                l.text,
              ),
          ],
          plain: plain,
          trackId: trackId,
          offsetMs: offsetMs + deltaMs,
          lrc: lrc,
          edited: edited,
        );

  Map<String, dynamic> toJson() => {
    'found': found,
    'synced': [for (final l in synced) l.toJson()],
    'plain': plain,
    'track_id': trackId,
    'offset_ms': offsetMs,
    'lrc': lrc,
    'edited': edited,
  };
}

abstract interface class LyricsRepository {
  /// Lança [ApiException].
  Future<Lyrics> lyrics(SearchResult track);

  /// Corrige a letra para todos: sincronia ([offsetMs]) e/ou texto ([lrc]
  /// com tempos, ou [plain]). Lança [ApiException] (o motivo vem em
  /// `serverMessage`).
  Future<Lyrics> edit(
    String trackId, {
    int? offsetMs,
    String? lrc,
    String? plain,
  });

  /// Desfaz a correção e busca de novo no LRCLIB.
  Future<Lyrics> reset(String trackId);
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

  @override
  Future<Lyrics> edit(
    String trackId, {
    int? offsetMs,
    String? lrc,
    String? plain,
  }) async {
    try {
      final r = await _dio.put<Map<String, dynamic>>(
        '/api/lyrics/$trackId',
        data: {'offset_ms': ?offsetMs, 'lrc': ?lrc, 'plain': ?plain},
      );
      return Lyrics.fromJson(r.data!);
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }

  @override
  Future<Lyrics> reset(String trackId) async {
    try {
      final r = await _dio.post<Map<String, dynamic>>(
        '/api/lyrics/$trackId/reset',
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
    trackId: 't1',
    lrc: '[00:05.00] Primeira linha da letra',
    synced: [
      LyricLine(Duration(seconds: 5), 'Primeira linha da letra'),
      LyricLine(Duration(seconds: 15), 'Segunda linha da letra'),
      LyricLine(Duration(seconds: 25), 'Terceira linha da letra'),
    ],
  );

  /// Correções recebidas (offset, lrc, plain).
  final edits = <({int? offsetMs, String? lrc, String? plain})>[];
  Lyrics? _edited;

  @override
  Future<Lyrics> lyrics(SearchResult track) async {
    calls++;
    if (_edited case final e?) return e;
    return track.title.contains('Instrumental') ? Lyrics.none : sample;
  }

  @override
  Future<Lyrics> edit(
    String trackId, {
    int? offsetMs,
    String? lrc,
    String? plain,
  }) async {
    edits.add((offsetMs: offsetMs, lrc: lrc, plain: plain));
    final base = _edited ?? sample;
    final delta = (offsetMs ?? base.offsetMs) - base.offsetMs;
    final next = base.shifted(delta);
    return _edited = Lyrics(
      found: true,
      synced: next.synced,
      plain: plain ?? next.plain,
      trackId: trackId,
      offsetMs: next.offsetMs,
      lrc: lrc ?? next.lrc,
      edited: true,
    );
  }

  @override
  Future<Lyrics> reset(String trackId) async {
    _edited = null;
    return sample;
  }
}

final lyricsRepositoryProvider = Provider<LyricsRepository>(
  (ref) => HttpLyricsRepository(ref.watch(apiDioProvider)),
);
