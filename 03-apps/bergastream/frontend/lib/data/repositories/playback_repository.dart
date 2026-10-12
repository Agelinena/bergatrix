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

/// Reprodução no servidor (Seção 9, área "Reprodução").
abstract interface class PlaybackRepository {
  /// `POST /api/play`: registra a faixa e enfileira o download.
  Future<PreparedTrack> prepare(SearchResult track);

  /// `GET /api/tracks/{id}/status`.
  Future<TrackReadiness> status(String trackId);

  /// URL de stream com token curto (`?t=`), que funciona igual em todas as
  /// plataformas (o `<audio>` da web não envia cabeçalhos). [quality] é o
  /// nível pedido (`AudioQuality.api`: original, high, normal, low).
  Future<Uri> streamUrl(String trackId, {String quality = 'original'});

  /// URL do arquivo completo (modo offline), com o mesmo token curto.
  Future<Uri> downloadUrl(String trackId, {String quality = 'original'});

  /// `POST /api/tracks/qualities`: para cada faixa (chave `SearchResult.id`,
  /// "provider:externalId"), o que cada nível entrega hoje. Faixa sem
  /// arquivo no servidor não vem.
  Future<Map<String, Map<String, TrackQuality>>> qualities(List<String> refs);
}

class HttpPlaybackRepository implements PlaybackRepository {
  HttpPlaybackRepository(this._dio);

  final Dio _dio;

  @override
  Future<PreparedTrack> prepare(SearchResult track) => _call(() async {
    final r = await _dio.post<Map<String, dynamic>>(
      '/api/play',
      data: track.toJson(),
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
  Future<Uri> streamUrl(String trackId, {String quality = 'original'}) =>
      _tokenUrl(trackId, 'stream', quality);

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

  Future<Uri> _tokenUrl(String trackId, String kind, String quality) => _call(
    () async {
      final r = await _dio.post<Map<String, dynamic>>(
        '/api/tracks/$trackId/stream-token',
      );
      final base = Uri.parse(_dio.options.baseUrl);
      return base.replace(
        path: '${base.path}/api/tracks/$trackId/$kind'.replaceAll('//', '/'),
        queryParameters: {'t': r.data!['token'] as String, 'quality': quality},
      );
    },
  );

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
