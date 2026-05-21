import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../models/track.dart';
import '../core/api_client.dart';
import '../services/offline_service.dart';
import 'connectivity_provider.dart';

part 'search_provider.g.dart';

class SearchState {
  final List<Track> tracks;
  final List<Map<String, dynamic>> albums;
  final List<Map<String, dynamic>> artists;
  final bool loading;
  final String? error;
  /// True quando o resultado veio da busca local em faixas baixadas
  /// (porque o device está offline ou a API falhou).
  final bool offline;

  const SearchState({
    this.tracks = const [],
    this.albums = const [],
    this.artists = const [],
    this.loading = false,
    this.error,
    this.offline = false,
  });

  SearchState copyWith({
    List<Track>? tracks,
    List<Map<String, dynamic>>? albums,
    List<Map<String, dynamic>>? artists,
    bool? loading,
    String? error,
    bool? offline,
  }) => SearchState(
    tracks: tracks ?? this.tracks,
    albums: albums ?? this.albums,
    artists: artists ?? this.artists,
    loading: loading ?? this.loading,
    error: error ?? this.error,
    offline: offline ?? this.offline,
  );
}

@riverpod
class Search extends _$Search {
  @override
  SearchState build() => const SearchState();

  Future<void> search(String query, {String source = 'deezer'}) async {
    if (query.isEmpty) {
      state = const SearchState();
      return;
    }
    state = state.copyWith(loading: true, error: null);

    final isOnline = ref.read(connectivityProvider);

    // Offline: search the downloaded-tracks set instead of the API.
    if (!isOnline) {
      await _searchLocal(query);
      return;
    }

    try {
      final client = ref.read(apiClientProvider);
      final data = await client.search(query, source: source);
      final tracks = (data['tracks'] as List<dynamic>)
          .map((t) => Track.fromJson(t as Map<String, dynamic>))
          .toList();
      final albums = (data['albums'] as List<dynamic>)
          .map((a) => a as Map<String, dynamic>)
          .toList();
      final artists = (data['artists'] as List<dynamic>)
          .map((a) => a as Map<String, dynamic>)
          .toList();
      state = SearchState(tracks: tracks, albums: albums, artists: artists);
    } catch (e) {
      // API failed even though we believed we were online — fall back to
      // local search so the user still gets something useful.
      await _searchLocal(query, errorHint: e.toString());
    }
  }

  /// Local fuzzy search over [OfflineService.getDownloadedTracks].
  Future<void> _searchLocal(String query, {String? errorHint}) async {
    try {
      final local = await OfflineService.getDownloadedTracks();
      final lower = query.toLowerCase();
      final matches = local.where((t) {
        return t.title.toLowerCase().contains(lower) ||
            t.artist.toLowerCase().contains(lower) ||
            (t.album ?? '').toLowerCase().contains(lower);
      }).toList();
      state = SearchState(
        tracks: matches,
        offline: true,
        // Errors from the failed online attempt are not surfaced — the
        // banner already tells the user we're offline.
        error: null,
      );
    } catch (e) {
      state = state.copyWith(
        loading: false,
        error: errorHint ?? 'Falha na busca local: $e',
        offline: true,
      );
    }
  }

  void clear() => state = const SearchState();
}
