import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_error.dart';
import '../../data/models/search_result.dart';
import '../../data/repositories/catalog_repository.dart';

/// Estado de "Todas as músicas".
class ArtistTracksState {
  const ArtistTracksState({
    this.items = const [],
    this.nextOffset = 0,
    this.total,
    this.loading = false,
    this.error,
  });

  final List<SearchResult> items;

  /// Nulo quando acabou.
  final int? nextOffset;
  final int? total;
  final bool loading;
  final ApiException? error;

  bool get hasMore => nextOffset != null;
}

/// Carrega "Todas as músicas" do artista página a página (offset), sem
/// repetir faixas e parando quando o servidor diz que acabou.
class ArtistTracksPager extends Notifier<ArtistTracksState> {
  ArtistTracksPager(this.key);

  /// (provider, id do artista).
  final (String, String) key;

  @override
  ArtistTracksState build() => const ArtistTracksState();

  Future<void> loadMore() async {
    final offset = state.nextOffset;
    if (state.loading || offset == null) return;
    state = ArtistTracksState(
      items: state.items,
      nextOffset: offset,
      total: state.total,
      loading: true,
    );
    try {
      final page = await ref
          .read(catalogRepositoryProvider)
          .artistTracks(key.$1, key.$2, offset: offset);
      if (!ref.mounted) return;
      final seen = {for (final t in state.items) t.id};
      state = ArtistTracksState(
        items: [
          ...state.items,
          for (final t in page.items)
            if (seen.add(t.id)) t,
        ],
        nextOffset: page.nextOffset,
        total: page.total,
      );
    } on ApiException catch (e) {
      if (!ref.mounted) return;
      state = ArtistTracksState(
        items: state.items,
        nextOffset: offset,
        total: state.total,
        error: e,
      );
    }
  }
}

final artistTracksProvider = NotifierProvider.autoDispose
    .family<ArtistTracksPager, ArtistTracksState, (String, String)>(
      ArtistTracksPager.new,
    );

Duration? _noRetry(int retryCount, Object error) => null;

final artistPageProvider = FutureProvider.autoDispose.family(
  (ref, (String, String) key) =>
      ref.read(catalogRepositoryProvider).artist(key.$1, key.$2),
  retry: _noRetry,
);

final albumPageProvider = FutureProvider.autoDispose.family(
  (ref, (String, String) key) =>
      ref.read(catalogRepositoryProvider).album(key.$1, key.$2),
  retry: _noRetry,
);

/// Filtro "Buscar neste artista/álbum": título, artista ou álbum.
List<SearchResult> filterTracks(List<SearchResult> tracks, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return tracks;
  return [
    for (final t in tracks)
      if ('${t.title} ${t.artist} ${t.album}'.toLowerCase().contains(q)) t,
  ];
}
