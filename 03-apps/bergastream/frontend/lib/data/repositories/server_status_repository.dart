import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_error.dart';
import '../api/api_dio.dart';

/// Situação do servidor (`GET /api/server/status`), mostrada em Ajustes.
class ServerStatus {
  const ServerStatus({
    required this.tracks,
    required this.permanent,
    required this.cache,
    required this.bytes,
    required this.bytesPermanent,
    required this.bytesCache,
    this.diskTotal,
    this.diskFree,
    required this.queueWaiting,
    required this.queueActive,
    required this.deemixAvailable,
    this.deemixDownloading = 0,
    this.deemixWaiting = 0,
    this.deemixFailed = 0,
    this.deemixItems = const [],
    this.deemixFailures = const [],
  });

  factory ServerStatus.fromJson(Map<String, dynamic> json) {
    final s = json['storage'] as Map<String, dynamic>;
    final q = json['queue'] as Map<String, dynamic>;
    final d = json['deemix'] as Map<String, dynamic>;
    return ServerStatus(
      tracks: s['tracks'] as int,
      permanent: s['permanent'] as int,
      cache: s['cache'] as int,
      bytes: s['bytes'] as int,
      bytesPermanent: s['bytes_permanent'] as int,
      bytesCache: s['bytes_cache'] as int,
      diskTotal: s['disk_total'] as int?,
      diskFree: s['disk_free'] as int?,
      queueWaiting: q['waiting'] as int,
      queueActive: q['active'] as int,
      deemixAvailable: d['available'] as bool,
      deemixDownloading: d['downloading'] as int? ?? 0,
      deemixWaiting: d['waiting'] as int? ?? 0,
      deemixFailed: d['failed'] as int? ?? 0,
      deemixItems: [
        for (final i in d['items'] as List<dynamic>? ?? const [])
          DeemixItem.fromJson(i as Map<String, dynamic>),
      ],
      deemixFailures: [
        for (final f in d['recent_failures'] as List<dynamic>? ?? const [])
          DeemixFailure.fromJson(f as Map<String, dynamic>),
      ],
    );
  }

  /// Músicas baixadas no servidor (permanentes + cache) e espaço ocupado.
  final int tracks;
  final int permanent;
  final int cache;
  final int bytes;
  final int bytesPermanent;
  final int bytesCache;

  /// Disco onde ficam as músicas.
  final int? diskTotal;
  final int? diskFree;

  /// Fila de downloads do Bergastream.
  final int queueWaiting;
  final int queueActive;

  final bool deemixAvailable;
  final int deemixDownloading;
  final int deemixWaiting;
  final int deemixFailed;

  /// Itens da fila do Deemix (baixando, esperando e com falha).
  final List<DeemixItem> deemixItems;

  /// Falhas recentes do Deemix e se o YouTube baixou no lugar.
  final List<DeemixFailure> deemixFailures;
}

class DeemixFailure {
  const DeemixFailure({
    required this.title,
    required this.artist,
    required this.error,
    required this.recovered,
  });

  factory DeemixFailure.fromJson(Map<String, dynamic> json) => DeemixFailure(
    title: json['title'] as String? ?? '',
    artist: json['artist'] as String? ?? '',
    error: json['error'] as String? ?? '',
    recovered: json['recovered'] as bool? ?? false,
  );

  final String title;
  final String artist;
  final String error;

  /// Baixada pelo YouTube no lugar.
  final bool recovered;
}

class DeemixItem {
  const DeemixItem({
    required this.title,
    required this.artist,
    required this.status,
    this.progress = 0,
  });

  factory DeemixItem.fromJson(Map<String, dynamic> json) => DeemixItem(
    title: json['title'] as String? ?? '',
    artist: json['artist'] as String? ?? '',
    status: json['status'] as String? ?? 'inQueue',
    progress: json['progress'] as int? ?? 0,
  );

  final String title;
  final String artist;

  /// `downloading`, `inQueue` ou `failed`.
  final String status;
  final int progress;

  String get statusLabel => switch (status) {
    'downloading' => 'baixando $progress%',
    'failed' => 'falhou',
    _ => 'na fila',
  };
}

abstract interface class ServerStatusRepository {
  /// Lança [ApiException].
  Future<ServerStatus> status();
}

class HttpServerStatusRepository implements ServerStatusRepository {
  HttpServerStatusRepository(this._dio);

  final Dio _dio;

  @override
  Future<ServerStatus> status() async {
    try {
      final r = await _dio.get<Map<String, dynamic>>('/api/server/status');
      return ServerStatus.fromJson(r.data!);
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }
}

/// Valores fixos (testes).
class FakeServerStatusRepository implements ServerStatusRepository {
  FakeServerStatusRepository([this.value = sample]);

  ServerStatus value;
  int calls = 0;

  static const sample = ServerStatus(
    tracks: 1200,
    permanent: 900,
    cache: 300,
    bytes: 9 * 1024 * 1024 * 1024,
    bytesPermanent: 7 * 1024 * 1024 * 1024,
    bytesCache: 2 * 1024 * 1024 * 1024,
    diskTotal: 1000 * 1024 * 1024 * 1024,
    diskFree: 400 * 1024 * 1024 * 1024,
    queueWaiting: 3,
    queueActive: 1,
    deemixAvailable: true,
    deemixDownloading: 1,
    deemixWaiting: 2,
    deemixItems: [
      DeemixItem(
        title: 'Bohemian Rhapsody',
        artist: 'Queen',
        status: 'downloading',
        progress: 40,
      ),
      DeemixItem(title: 'Levitating', artist: 'Dua Lipa', status: 'inQueue'),
    ],
    deemixFailures: [
      DeemixFailure(
        title: 'Redbone',
        artist: 'Childish Gambino',
        error: "reading 'HREF'",
        recovered: true,
      ),
      DeemixFailure(
        title: 'Rara',
        artist: 'Alguém',
        error: 'não baixou',
        recovered: false,
      ),
    ],
  );

  @override
  Future<ServerStatus> status() async {
    calls++;
    return value;
  }
}

final serverStatusRepositoryProvider = Provider<ServerStatusRepository>(
  (ref) => HttpServerStatusRepository(ref.watch(apiDioProvider)),
);

final serverStatusProvider = FutureProvider.autoDispose<ServerStatus>(
  (ref) => ref.read(serverStatusRepositoryProvider).status(),
  retry: (_, _) => null,
);

/// De quanto em quanto tempo Ajustes atualiza o painel (nulo nos testes).
final serverStatusRefreshProvider = Provider<Duration?>(
  (ref) => const Duration(seconds: 10),
);
