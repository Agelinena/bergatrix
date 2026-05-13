import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../models/track.dart';
import '../core/api_client.dart';

part 'search_provider.g.dart';

class SearchState {
  final List<Track> tracks;
  final List<Map<String, dynamic>> albums;
  final List<Map<String, dynamic>> artists;
  final bool loading;
  final String? error;

  const SearchState({
    this.tracks = const [],
    this.albums = const [],
    this.artists = const [],
    this.loading = false,
    this.error,
  });

  SearchState copyWith({
    List<Track>? tracks,
    List<Map<String, dynamic>>? albums,
    List<Map<String, dynamic>>? artists,
    bool? loading,
    String? error,
  }) => SearchState(
    tracks: tracks ?? this.tracks,
    albums: albums ?? this.albums,
    artists: artists ?? this.artists,
    loading: loading ?? this.loading,
    error: error ?? this.error,
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
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  void clear() => state = const SearchState();
}
