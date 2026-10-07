import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_error.dart';
import '../api/api_dio.dart';
import '../models/search_full.dart';
import '../models/search_result.dart';
import 'fake_catalog.dart';

/// Origem da busca (chips da Seção 6.3).
enum SearchSource {
  spotify('spotify', 'Spotify'),
  ytMusic('ytmusic', 'YT Music');

  const SearchSource(this.apiValue, this.label);

  final String apiValue;
  final String label;
}

/// Busca no servidor: faixas, artistas e álbuns (`/api/search/full`) e
/// links (`/api/resolve`).
abstract interface class SearchRepository {
  /// Lança [ApiException].
  Future<FullSearchResult> search(String query, SearchSource source);

  /// Lança [ApiException] (400 = link não reconhecido, 404 = não abriu).
  Future<ResolvedLink> resolve(String url);

  /// Playlists do Spotify, Deezer e YouTube Music ("rádio X" traz a rádio
  /// do artista). Lança [ApiException].
  Future<List<PlaylistResult>> searchPlaylists(String query);
}

class HttpSearchRepository implements SearchRepository {
  HttpSearchRepository(this._dio);

  final Dio _dio;

  @override
  Future<FullSearchResult> search(String query, SearchSource source) =>
      _call(() async {
        final r = await _dio.get<Map<String, dynamic>>(
          '/api/search/full',
          queryParameters: {'q': query, 'source': source.apiValue},
        );
        return FullSearchResult.fromJson(r.data!);
      });

  @override
  Future<ResolvedLink> resolve(String url) => _call(() async {
    final r = await _dio.get<Map<String, dynamic>>(
      '/api/resolve',
      queryParameters: {'url': url},
      // Playlists grandes (até 10.000 faixas) levam minutos para ler.
      options: Options(receiveTimeout: const Duration(minutes: 5)),
    );
    return ResolvedLink.fromJson(r.data!);
  });

  @override
  Future<List<PlaylistResult>> searchPlaylists(String query) => _call(() async {
    final r = await _dio.get<List<dynamic>>(
      '/api/search/playlists',
      queryParameters: {'q': query},
    );
    return [
      for (final p in r.data ?? const [])
        PlaylistResult.fromJson(p as Map<String, dynamic>),
    ];
  });

  static Future<T> _call<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }
}

/// Busca nos dados fictícios do protótipo (testes).
class FakeSearchRepository implements SearchRepository {
  int calls = 0;
  int resolveCalls = 0;

  static SearchResult trackOf(int i, SearchSource source) {
    final t = FakeCatalog.tracks[i];
    return SearchResult(
      provider: source.apiValue,
      externalId: t.id,
      title: t.title,
      artist: t.artist,
      album: t.album,
      durationSeconds: t.durationSeconds,
    );
  }

  @override
  Future<FullSearchResult> search(String query, SearchSource source) async {
    calls++;
    final q = query.toLowerCase();
    final tracks = [
      for (final (i, t) in FakeCatalog.tracks.indexed)
        if ('${t.title}${t.artist}${t.album}'.toLowerCase().contains(q))
          trackOf(i, source),
    ];
    return FullSearchResult(
      tracks: tracks,
      artists: [
        for (final name in {for (final t in tracks) t.artist})
          SearchArtist(provider: source.apiValue, externalId: name, name: name),
      ],
      albums: [
        for (final t in {for (final t in tracks) t.album: t}.values)
          SearchAlbum(
            provider: source.apiValue,
            externalId: t.album,
            title: t.album,
            artist: t.artist,
          ),
      ],
    );
  }

  @override
  /// Playlists só para buscas com "rock" ou "rádio" (as outras buscas dos
  /// testes ficam como antes).
  @override
  Future<List<PlaylistResult>> searchPlaylists(String query) async {
    final q = query.toLowerCase();
    return [
      if (q.startsWith('rádio') || q.startsWith('radio'))
        const PlaylistResult(
          provider: 'ytmusic',
          externalId: 'RDEMx',
          title: 'Rádio Scorpions',
          owner: 'YouTube Music',
          url: 'https://music.youtube.com/playlist?list=RDEMx',
          isRadio: true,
        ),
      if (q.contains('rock'))
        const PlaylistResult(
          provider: 'deezer',
          externalId: '5619143162',
          title: 'Rock Brasil Anos 80',
          owner: 'Editores Deezer Brasil',
          trackCount: 40,
          url: 'https://www.deezer.com/playlist/5619143162',
        ),
    ];
  }

  @override
  Future<ResolvedLink> resolve(String url) async {
    resolveCalls++;
    if (url.contains('naoabre')) {
      throw const ApiException(ApiErrorKind.naoEncontrado, statusCode: 404);
    }
    final source = url.contains('deezer')
        ? 'deezer'
        : url.contains('youtu')
        ? 'youtube'
        : 'spotify';
    if (url.contains('/track/')) {
      final t = trackOf(2, SearchSource.spotify);
      return ResolvedLink(
        source: source,
        kind: 'track',
        title: t.title,
        subtitle: t.artist,
        total: 1,
        tracks: [t],
        externalUrl: url,
      );
    }
    return ResolvedLink(
      source: source,
      kind: 'playlist',
      title: 'Roadtrip importada',
      subtitle: 'Ana',
      description: 'Para pegar a estrada',
      total: 3,
      tracks: [for (var i = 0; i < 3; i++) trackOf(i, SearchSource.spotify)],
      externalUrl: url,
    );
  }
}

final searchRepositoryProvider = Provider<SearchRepository>(
  (ref) => HttpSearchRepository(ref.watch(apiDioProvider)),
);
