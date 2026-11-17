import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_error.dart';
import '../api/api_dio.dart';
import '../models/search_result.dart';

/// Pedido de uma leva da rádio (`POST /api/radio`). O app guarda o estado da
/// rádio e manda tudo a cada pedido; o servidor não guarda sessão.
class RadioRequest {
  const RadioRequest({
    required this.seed,
    this.recent = const [],
    this.skipped = const {},
    this.exclude = const [],
    this.lastArtist,
    this.count = 15,
  });

  /// A música que começou a rádio (a âncora do tema).
  final SearchResult seed;

  /// Até 2 recentes ouvidas sem pular.
  final List<SearchResult> recent;

  /// Artista -> vezes que foi pulado antes dos 30 s.
  final Map<String, int> skipped;

  /// Já tocou nesta rádio ou está na fila.
  final List<SearchResult> exclude;
  final String? lastArtist;
  final int count;

  Map<String, Object?> toJson() => {
    'seed': seed.toJson(),
    'recent': [for (final r in recent.take(2)) r.toJson()],
    'skipped': skipped,
    'exclude': [
      for (final e in exclude.take(600)) {'artist': e.artist, 'title': e.title},
    ],
    'last_artist': lastArtist,
    'count': count,
  };
}

/// Lança [ApiException] (429 = muitas rádios seguidas, 409 = substituída).
abstract interface class RadioRepository {
  Future<List<SearchResult>> next(RadioRequest request);
}

class HttpRadioRepository implements RadioRepository {
  HttpRadioRepository(this._dio);

  final Dio _dio;

  @override
  Future<List<SearchResult>> next(RadioRequest request) async {
    try {
      final r = await _dio.post<Map<String, dynamic>>(
        '/api/radio',
        data: request.toJson(),
      );
      return [
        for (final t in (r.data?['tracks'] as List<dynamic>? ?? const []))
          SearchResult.fromJson(t as Map<String, dynamic>),
      ];
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }
}

/// Para testes e o modo demonstração: devolve [batches] em ordem e guarda
/// os pedidos.
class FakeRadioRepository implements RadioRepository {
  FakeRadioRepository([List<List<SearchResult>>? batches])
    : batches = batches ?? [];

  final List<List<SearchResult>> batches;
  final requests = <RadioRequest>[];

  @override
  Future<List<SearchResult>> next(RadioRequest request) async {
    requests.add(request);
    if (batches.isEmpty) return const [];
    return batches.removeAt(0);
  }
}

final radioRepositoryProvider = Provider<RadioRepository>(
  (ref) => HttpRadioRepository(ref.watch(apiDioProvider)),
);
