import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_error.dart';
import '../api/api_dio.dart';
import '../models/search_result.dart';

/// Música que não deu para baixar (`/api/admin/failures`).
class DownloadFailure {
  const DownloadFailure({
    required this.trackId,
    required this.title,
    required this.artist,
    this.album = '',
    this.durationSeconds = 0,
    this.coverUrl,
    this.error,
    this.attempts = 1,
    this.lastFailedAt,
    this.ignored = false,
    this.playlists = 0,
    this.queued = false,
  });

  factory DownloadFailure.fromJson(Map<String, dynamic> json) =>
      DownloadFailure(
        trackId: json['track_id'] as String,
        title: json['title'] as String,
        artist: json['artist'] as String,
        album: json['album'] as String? ?? '',
        durationSeconds: json['duration_seconds'] as int? ?? 0,
        coverUrl: json['cover_url'] as String?,
        error: json['error'] as String?,
        attempts: json['attempts'] as int? ?? 1,
        lastFailedAt: DateTime.tryParse('${json['last_failed_at']}')?.toLocal(),
        ignored: json['ignored'] == true,
        playlists: json['playlists'] as int? ?? 0,
        queued: json['queued'] == true,
      );

  final String trackId;
  final String title;
  final String artist;
  final String album;
  final int durationSeconds;
  final String? coverUrl;
  final String? error;
  final int attempts;
  final DateTime? lastFailedAt;
  final bool ignored;

  /// Em quantas playlists a música está.
  final int playlists;

  /// Já está na fila de novo.
  final bool queued;
}

/// Aba "Músicas com erro" do admin. Lança [ApiException].
abstract interface class FailuresRepository {
  Future<List<DownloadFailure>> list({bool ignored = false});
  Future<void> retry(String trackId);

  /// Versões no YouTube Music e no Deezer ([query] vazio = artista e título).
  Future<List<SearchResult>> candidates(String trackId, {String query = ''});

  /// Baixa a música desta fonte.
  Future<void> chooseSource(String trackId, SearchResult source);
  Future<void> setIgnored(String trackId, bool ignored);
}

class HttpFailuresRepository implements FailuresRepository {
  HttpFailuresRepository(this._dio);

  final Dio _dio;
  static const _base = '/api/admin/failures';

  Future<T> _call<T>(Future<T> Function() run) async {
    try {
      return await run();
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }

  @override
  Future<List<DownloadFailure>> list({bool ignored = false}) => _call(() async {
    final r = await _dio.get<List<dynamic>>(
      _base,
      queryParameters: {'ignored': ignored},
    );
    return [
      for (final f in r.data ?? const [])
        DownloadFailure.fromJson(f as Map<String, dynamic>),
    ];
  });

  @override
  Future<void> retry(String trackId) =>
      _call(() => _dio.post<void>('$_base/$trackId/retry'));

  @override
  Future<List<SearchResult>> candidates(String trackId, {String query = ''}) =>
      _call(() async {
        final r = await _dio.get<List<dynamic>>(
          '$_base/$trackId/candidates',
          queryParameters: {if (query.isNotEmpty) 'q': query},
        );
        return [
          for (final s in r.data ?? const [])
            SearchResult.fromJson(s as Map<String, dynamic>),
        ];
      });

  @override
  Future<void> chooseSource(String trackId, SearchResult source) => _call(
    () => _dio.post<void>(
      '$_base/$trackId/source',
      data: {'provider': source.provider, 'external_id': source.externalId},
    ),
  );

  @override
  Future<void> setIgnored(String trackId, bool ignored) => _call(
    () => _dio.post<void>('$_base/$trackId/ignore', data: {'ignored': ignored}),
  );
}

/// Falhas em memória (testes).
class FakeFailuresRepository implements FailuresRepository {
  FakeFailuresRepository([List<DownloadFailure>? items]) : items = items ?? [];

  final List<DownloadFailure> items;
  final retried = <String>[];
  final chosen = <(String, String)>[];
  final queries = <String>[];
  List<SearchResult> found = const [];

  @override
  Future<List<DownloadFailure>> list({bool ignored = false}) async => [
    for (final f in items)
      if (f.ignored == ignored) f,
  ];

  @override
  Future<void> retry(String trackId) async => retried.add(trackId);

  @override
  Future<List<SearchResult>> candidates(
    String trackId, {
    String query = '',
  }) async {
    queries.add(query);
    return found;
  }

  @override
  Future<void> chooseSource(String trackId, SearchResult source) async =>
      chosen.add((trackId, source.externalId));

  @override
  Future<void> setIgnored(String trackId, bool ignored) async {
    final i = items.indexWhere((f) => f.trackId == trackId);
    final f = items[i];
    items[i] = DownloadFailure(
      trackId: f.trackId,
      title: f.title,
      artist: f.artist,
      error: f.error,
      attempts: f.attempts,
      ignored: ignored,
      playlists: f.playlists,
    );
  }
}

final failuresRepositoryProvider = Provider<FailuresRepository>(
  (ref) => HttpFailuresRepository(ref.watch(apiDioProvider)),
);
