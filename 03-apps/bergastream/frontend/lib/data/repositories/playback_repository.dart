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

/// Reprodução no servidor (Seção 9, área "Reprodução").
abstract interface class PlaybackRepository {
  /// `POST /api/play`: registra a faixa e enfileira o download.
  Future<PreparedTrack> prepare(SearchResult track);

  /// `GET /api/tracks/{id}/status`.
  Future<TrackReadiness> status(String trackId);

  /// URL de stream com token curto (`?t=`), que funciona igual em todas as
  /// plataformas (o `<audio>` da web não envia cabeçalhos).
  Future<Uri> streamUrl(String trackId);

  /// URL do arquivo completo (modo offline), com o mesmo token curto.
  Future<Uri> downloadUrl(String trackId);
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
  Future<Uri> streamUrl(String trackId) => _tokenUrl(trackId, 'stream');

  @override
  Future<Uri> downloadUrl(String trackId) => _tokenUrl(trackId, 'download');

  Future<Uri> _tokenUrl(String trackId, String kind) => _call(() async {
    final r = await _dio.post<Map<String, dynamic>>(
      '/api/tracks/$trackId/stream-token',
    );
    final base = Uri.parse(_dio.options.baseUrl);
    return base.replace(
      path: '${base.path}/api/tracks/$trackId/$kind'.replaceAll('//', '/'),
      queryParameters: {'t': r.data!['token'] as String},
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
