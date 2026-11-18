import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_error.dart';
import '../api/api_dio.dart';
import '../models/search_result.dart';

/// Estado de preparo de uma faixa no servidor (`/api/tracks/{id}/status`).
enum TrackReadiness { pronta, baixando, erro, desconhecido }

TrackReadiness readinessFrom(String? status) => switch (status) {
  'ready' || 'done' => TrackReadiness.pronta,
  'downloading' || 'queued' || 'registered' => TrackReadiness.baixando,
  'error' || 'failed' => TrackReadiness.erro,
  _ => TrackReadiness.desconhecido,
};

/// Faixa registrada no servidor ao pedir para tocar.
class PreparedTrack {
  const PreparedTrack(this.trackId, this.readiness);

  final String trackId;
  final TrackReadiness readiness;
}

/// O que o servidor entrega num nível de qualidade ("FLAC 16/44.1", "MP3
/// 320", "AAC 160"); [rank] ordena (10 baixa … 50 hi-res).
class TrackQuality {
  const TrackQuality(this.label, this.rank);

  factory TrackQuality.fromJson(Map<String, dynamic> json) =>
      TrackQuality(json['label'] as String? ?? '', json['rank'] as int? ?? 0);

  final String label;
  final int rank;
}

/// Volume percebido do arquivo no servidor (EBU R128): [lufs] integrado e
/// [peak] (pico real, dBTP). O player abaixa as músicas mais altas.
class TrackLoudness {
  const TrackLoudness(this.lufs, this.peak);

  factory TrackLoudness.fromJson(Map<String, dynamic> json) => TrackLoudness(
    (json['lufs'] as num).toDouble(),
    (json['peak'] as num?)?.toDouble() ?? 0,
  );

  final double lufs;
  final double peak;

  Map<String, dynamic> toJson() => {'lufs': lufs, 'peak': peak};
}

/// Reprodução no servidor (Seção 9, área "Reprodução").
abstract interface class PlaybackRepository {
  /// `POST /api/play`: registra a faixa e enfileira o download. [prefetch]
  /// = só adiantando as próximas (fila média, atrás de quem quer ouvir já).
  Future<PreparedTrack> prepare(SearchResult track, {bool prefetch = false});

  /// `GET /api/tracks/{id}/status`.
  Future<TrackReadiness> status(String trackId);

  /// URL de stream com token curto (`?t=`), que funciona igual em todas as
  /// plataformas (o `<audio>` da web não envia cabeçalhos). [quality] é o
  /// nível pedido (`AudioQuality.api`: original, high, normal, low). Com
  /// [norm] (LUFS alvo), o servidor entrega a faixa já normalizada (se o
  /// volume dela já foi medido).
  Future<Uri> streamUrl(
    String trackId, {
    String quality = 'original',
    double? norm,
  });

  /// Pede o começo do stream para o servidor deixar pronta a versão no
  /// nível e volume pedidos (a troca para a próxima fica instantânea).
  Future<void> warm(
    String trackId, {
    String quality = 'original',
    double? norm,
  });

  /// URL do arquivo completo (modo offline), com o mesmo token curto.
  Future<Uri> downloadUrl(String trackId, {String quality = 'original'});

  /// `POST /api/tracks/qualities`: para cada faixa (chave `SearchResult.id`,
  /// "provider:externalId"), o que cada nível entrega hoje. Faixa sem
  /// arquivo no servidor não vem.
  Future<Map<String, Map<String, TrackQuality>>> qualities(List<String> refs);

  /// `POST /api/tracks/loudness`: volume percebido por faixa
  /// ("provider:externalId"). Faixa ainda não medida não vem.
  Future<Map<String, TrackLoudness>> loudness(List<String> refs);

  /// `POST /api/tracks/redownload`: apaga o arquivo no servidor e baixa de
  /// novo (áudio errado ou cortado).
  Future<PreparedTrack> redownload(SearchResult track);
}

class HttpPlaybackRepository implements PlaybackRepository {
  HttpPlaybackRepository(this._dio);

  final Dio _dio;

  @override
  Future<PreparedTrack> prepare(SearchResult track, {bool prefetch = false}) =>
      _call(() async {
        final r = await _dio.post<Map<String, dynamic>>(
          '/api/play',
          data: track.toJson(),
          queryParameters: {if (prefetch) 'prefetch': true},
        );
        return PreparedTrack(
          r.data!['track_id'] as String,
          readinessFrom(r.data!['status'] as String?),
        );
      });

  @override
  Future<TrackReadiness> status(String trackId) => _call(() async {
    final r = await _dio.get<Map<String, dynamic>>(
      '/api/tracks/$trackId/status',
    );
    return readinessFrom(r.data!['status'] as String?);
  });

  @override
  Future<Uri> streamUrl(
    String trackId, {
    String quality = 'original',
    double? norm,
  }) => _tokenUrl(trackId, 'stream', quality, norm: norm);

  @override
  Future<void> warm(
    String trackId, {
    String quality = 'original',
    double? norm,
  }) async {
    final url = await streamUrl(trackId, quality: quality, norm: norm);
    await _call(
      () => _dio.getUri<void>(
        url,
        options: Options(
          headers: {'Range': 'bytes=0-1'},
          responseType: ResponseType.bytes,
        ),
      ),
    );
  }

  @override
  Future<Uri> downloadUrl(String trackId, {String quality = 'original'}) =>
      _tokenUrl(trackId, 'download', quality);

  @override
  Future<Map<String, Map<String, TrackQuality>>> qualities(List<String> refs) =>
      _call(() async {
        if (refs.isEmpty) return const {};
        final r = await _dio.post<Map<String, dynamic>>(
          '/api/tracks/qualities',
          data: {'refs': refs},
        );
        return {
          for (final MapEntry(:key, :value) in (r.data ?? const {}).entries)
            key: {
              for (final MapEntry(key: level, value: q)
                  in (value as Map<String, dynamic>).entries)
                level: TrackQuality.fromJson(q as Map<String, dynamic>),
            },
        };
      });

  @override
  Future<Map<String, TrackLoudness>> loudness(List<String> refs) =>
      _call(() async {
        if (refs.isEmpty) return const {};
        final r = await _dio.post<Map<String, dynamic>>(
          '/api/tracks/loudness',
          data: {'refs': refs},
        );
        return {
          for (final MapEntry(:key, :value) in (r.data ?? const {}).entries)
            key: TrackLoudness.fromJson(value as Map<String, dynamic>),
        };
      });

  @override
  Future<PreparedTrack> redownload(SearchResult track) => _call(() async {
    final r = await _dio.post<Map<String, dynamic>>(
      '/api/tracks/redownload',
      data: track.toJson(),
    );
    return PreparedTrack(
      r.data!['track_id'] as String,
      readinessFrom(r.data!['status'] as String?),
    );
  });

  Future<Uri> _tokenUrl(
    String trackId,
    String kind,
    String quality, {
    double? norm,
  }) => _call(() async {
    final r = await _dio.post<Map<String, dynamic>>(
      '/api/tracks/$trackId/stream-token',
    );
    final base = Uri.parse(_dio.options.baseUrl);
    return base.replace(
      path: '${base.path}/api/tracks/$trackId/$kind'.replaceAll('//', '/'),
      queryParameters: {
        't': r.data!['token'] as String,
        'quality': quality,
        if (norm != null) 'norm': norm.round().toString(),
      },
    );
  });

  static Future<T> _call<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }
}

final playbackRepositoryProvider = Provider<PlaybackRepository>(
  (ref) => HttpPlaybackRepository(ref.watch(apiDioProvider)),
);
