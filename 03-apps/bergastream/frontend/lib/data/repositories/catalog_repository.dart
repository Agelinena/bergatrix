import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_error.dart';
import '../api/api_dio.dart';
import '../models/catalog.dart';
import '../models/search_full.dart';
import '../models/search_result.dart';

/// Páginas de artista e álbum (Seção 6.7).
abstract interface class CatalogRepository {
  Future<ArtistPage> artist(String provider, String id);

  /// "Todas as músicas", paginado por offset.
  Future<TrackPage> artistTracks(
    String provider,
    String id, {
    required int offset,
    int limit = 50,
  });

  Future<AlbumPage> album(String provider, String id);
}

class HttpCatalogRepository implements CatalogRepository {
  HttpCatalogRepository(this._dio);

  final Dio _dio;

  // Os ids do YT Music podem ter caracteres que precisam ir codificados.
  String _seg(String id) => Uri.encodeComponent(id);

  @override
  Future<ArtistPage> artist(String provider, String id) => _call(() async {
    final r = await _dio.get<Map<String, dynamic>>(
      '/api/artists/$provider/${_seg(id)}',
    );
    return ArtistPage.fromJson(r.data!);
  });

  @override
  Future<TrackPage> artistTracks(
    String provider,
    String id, {
    required int offset,
    int limit = 50,
  }) => _call(() async {
    final r = await _dio.get<Map<String, dynamic>>(
      '/api/artists/$provider/${_seg(id)}/tracks',
      queryParameters: {'offset': offset, 'limit': limit},
      options: Options(receiveTimeout: const Duration(seconds: 90)),
    );
    return TrackPage.fromJson(r.data!);
  });

  @override
  Future<AlbumPage> album(String provider, String id) => _call(() async {
    final r = await _dio.get<Map<String, dynamic>>(
      '/api/albums/$provider/${_seg(id)}',
    );
    return AlbumPage.fromJson(r.data!);
  });

  static Future<T> _call<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }
}

/// Catálogo em memória para os testes: artista com [totalTracks] faixas.
class FakeCatalogRepository implements CatalogRepository {
  FakeCatalogRepository({this.totalTracks = 120, this.failPageAt});

  final int totalTracks;

  /// Offset em que a próxima página falha (uma vez).
  int? failPageAt;
  final requestedOffsets = <int>[];

  static SearchResult track(int i, {String album = 'Álbum 1'}) => SearchResult(
    provider: 'spotify',
    externalId: 't$i',
    title: 'Faixa $i',
    artist: 'Banda',
    album: album,
    durationSeconds: 180,
    artistId: 'banda',
    albumId: 'al1',
  );

  @override
  Future<ArtistPage> artist(String provider, String id) async => ArtistPage(
    provider: provider,
    externalId: id,
    name: 'Banda',
    followers: 1234567,
    topTracks: [for (var i = 0; i < 5; i++) track(i)],
    albums: const [
      SearchAlbum(
        provider: 'spotify',
        externalId: 'al1',
        title: 'Álbum 1',
        year: '2020',
      ),
      SearchAlbum(
        provider: 'spotify',
        externalId: 'al2',
        title: 'Álbum 2',
        year: '2022',
      ),
    ],
  );

  @override
  Future<TrackPage> artistTracks(
    String provider,
    String id, {
    required int offset,
    int limit = 50,
  }) async {
    requestedOffsets.add(offset);
    if (failPageAt == offset) {
      failPageAt = null;
      throw const ApiException(ApiErrorKind.servidor);
    }
    final end = (offset + limit).clamp(0, totalTracks);
    return TrackPage(
      items: [for (var i = offset; i < end; i++) track(i)],
      offset: offset,
      total: totalTracks,
      nextOffset: end < totalTracks ? end : null,
    );
  }

  @override
  Future<AlbumPage> album(String provider, String id) async => AlbumPage(
    provider: provider,
    externalId: id,
    title: 'Álbum 1',
    artist: 'Banda',
    artistId: 'banda',
    year: '2020',
    tracks: [for (var i = 0; i < 10; i++) track(i)],
  );
}

final catalogRepositoryProvider = Provider<CatalogRepository>(
  (ref) => HttpCatalogRepository(ref.watch(apiDioProvider)),
);
