import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local/database.dart';
import '../../data/models/search_full.dart';
import '../../data/repositories/search_repository.dart';

/// Sem repetição automática do Riverpod: quem decide tentar de novo é o
/// usuário ("Tentar de novo").
Duration? _noRetry(int retryCount, Object error) => null;

/// Resultado de uma busca (termo + origem). Fica em cache enquanto a tela
/// usa o mesmo termo.
final searchResultsProvider = FutureProvider.autoDispose
    .family<FullSearchResult, (String, SearchSource)>(
      (ref, key) => ref.read(searchRepositoryProvider).search(key.$1, key.$2),
      retry: _noRetry,
    );

/// Playlists achadas na busca (seção "Playlists"). Vazia se falhar: as
/// outras seções continuam.
final playlistSearchProvider = FutureProvider.autoDispose
    .family<List<PlaylistResult>, (String, SearchSource)>((ref, key) async {
      try {
        return await ref
            .read(searchRepositoryProvider)
            .searchPlaylists(key.$1, key.$2);
      } on Object {
        return const [];
      }
    }, retry: _noRetry);

/// Link resolvido (usado pela Busca e pela tela da playlist importada).
final resolvedLinkProvider = FutureProvider.autoDispose
    .family<ResolvedLink, String>(
      (ref, url) => ref.read(searchRepositoryProvider).resolve(url),
      retry: _noRetry,
    );

/// Busca nas músicas baixadas (sem servidor).
final localSearchProvider = FutureProvider.autoDispose
    .family<List<LocalTrack>, String>((ref, query) async {
      final db = ref.watch(localDatabaseProvider);
      return db == null ? const [] : db.searchDownloaded(query);
    });
