import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_error.dart';
import '../api/api_dio.dart';
import '../models/search_result.dart';
import '../models/stats.dart';

/// Uma reprodução contada (30 s ou metade da faixa). [clientId] é único:
/// reenviar a mesma não duplica no servidor.
class PlayRecord {
  PlayRecord({
    required this.track,
    required this.playedAt,
    String? clientId,
    this.playlistId,
  }) : clientId = clientId ?? newClientId();

  factory PlayRecord.fromJson(Map<String, dynamic> json) => PlayRecord(
    track: SearchResult.fromJson(json['track'] as Map<String, dynamic>),
    playedAt: DateTime.parse(json['played_at'] as String),
    clientId: json['client_id'] as String,
    playlistId: json['playlist_id'] as String?,
  );

  final SearchResult track;
  final DateTime playedAt;
  final String clientId;

  /// Tocada a partir desta playlist (ordem da Biblioteca).
  final String? playlistId;

  Map<String, dynamic> toJson() => {
    'client_id': clientId,
    'played_at': playedAt.toUtc().toIso8601String(),
    'track': track.toJson(),
    'playlist_id': ?playlistId,
  };

  /// UUID v4 (sem pacote extra).
  static String newClientId() {
    final r = Random.secure();
    final b = List<int>.generate(16, (_) => r.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
        '${h.substring(16, 20)}-${h.substring(20)}';
  }
}

/// Histórico de reprodução e métricas (Seção 9, área "Histórico").
abstract interface class HistoryRepository {
  /// Envia reproduções (na ordem). Lança [ApiException].
  Future<void> record(List<PlayRecord> plays);

  Future<ListeningStats> stats();
}

class HttpHistoryRepository implements HistoryRepository {
  HttpHistoryRepository(this._dio);

  final Dio _dio;

  @override
  Future<void> record(List<PlayRecord> plays) async {
    try {
      await _dio.post<void>(
        '/api/history',
        data: {
          'plays': [for (final p in plays) p.toJson()],
        },
      );
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }

  @override
  Future<ListeningStats> stats() async {
    try {
      final r = await _dio.get<Map<String, dynamic>>('/api/me/stats');
      return ListeningStats.fromJson(r.data!);
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }
}

/// Em memória (testes).
class FakeHistoryRepository implements HistoryRepository {
  FakeHistoryRepository({this.failing = false, this.statsValue});

  bool failing;
  final sent = <PlayRecord>[];
  ListeningStats? statsValue;

  @override
  Future<void> record(List<PlayRecord> plays) async {
    if (failing) throw const ApiException(ApiErrorKind.semConexao);
    for (final p in plays) {
      if (!sent.any((s) => s.clientId == p.clientId)) sent.add(p);
    }
  }

  @override
  Future<ListeningStats> stats() async {
    if (failing) throw const ApiException(ApiErrorKind.semConexao);
    return statsValue ?? const ListeningStats(month: '2026-10');
  }
}

final historyRepositoryProvider = Provider<HistoryRepository>(
  (ref) => HttpHistoryRepository(ref.watch(apiDioProvider)),
);
