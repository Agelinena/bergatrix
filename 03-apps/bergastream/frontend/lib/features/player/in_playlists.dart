import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/routes.dart';
import '../../core/theme/berga_colors.dart';
import '../../core/theme/berga_sizes.dart';
import '../../core/theme/berga_text.dart';
import '../../data/api/api_dio.dart';
import '../../data/models/search_result.dart';
import '../auth/session.dart';

/// Playlist em que a música está (`GET /api/me/playlists/containing`).
typedef PlaylistRef = ({String id, String name});

/// Lança qualquer erro; quem chama mostra nada.
abstract interface class InPlaylistsLookup {
  Future<List<PlaylistRef>> find(SearchResult track);
}

class HttpInPlaylistsLookup implements InPlaylistsLookup {
  HttpInPlaylistsLookup(this._dio);

  final Dio _dio;

  @override
  Future<List<PlaylistRef>> find(SearchResult track) async {
    final r = await _dio.get<List<dynamic>>(
      '/api/me/playlists/containing',
      queryParameters: {
        'title': track.title,
        'artist': track.artist,
        'provider': track.provider,
        'external_id': track.externalId,
        if (track.isrc != null) 'isrc': track.isrc,
      },
    );
    return [
      for (final p in r.data ?? const [])
        (
          id: (p as Map<String, dynamic>)['id'] as String,
          name: p['name'] as String,
        ),
    ];
  }
}

/// Testes: playlists fixas por id de música.
class FakeInPlaylistsLookup implements InPlaylistsLookup {
  FakeInPlaylistsLookup([this.byTrack = const {}]);

  final Map<String, List<PlaylistRef>> byTrack;

  @override
  Future<List<PlaylistRef>> find(SearchResult track) async =>
      byTrack[track.id] ?? byTrack[track.title] ?? const [];
}

final inPlaylistsLookupProvider = Provider<InPlaylistsLookup>(
  (ref) => HttpInPlaylistsLookup(ref.watch(apiDioProvider)),
);

/// Em quais playlists suas a música está (vale a mesma música por outra
/// fonte ou versão). Vazio sem servidor ou se der erro.
final inPlaylistsProvider = FutureProvider.autoDispose
    .family<List<PlaylistRef>, SearchResult>((ref, track) async {
      if (!ref.watch(sessionProvider).canUseServer) return const [];
      try {
        return await ref.read(inPlaylistsLookupProvider).find(track);
      } on Object catch (e) {
        debugPrint('Playlists da música: $e');
        return const [];
      }
    });

/// "Na sua playlist X" / "Em 3 playlists suas", embaixo do título no player.
/// Tocar abre a playlist (ou a lista, se forem várias).
class InPlaylistsLabel extends ConsumerWidget {
  const InPlaylistsLabel({super.key, required this.track, this.beforeOpen});

  final SearchResult track;

  /// Fecha o player antes de abrir a playlist.
  final VoidCallback? beforeOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final found = ref.watch(inPlaylistsProvider(track)).value ?? const [];
    if (found.isEmpty) return const SizedBox.shrink();
    final c = BergaColors.of(context);
    final router = GoRouter.of(context);
    void open(PlaylistRef p) {
      beforeOpen?.call();
      router.push(AppRoutes.playlist(p.id));
    }

    final label = found.length == 1
        ? 'Na sua playlist ${found.single.name}'
        : 'Em ${found.length} playlists suas';
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (found.length == 1) {
            open(found.single);
            return;
          }
          showModalBottomSheet<void>(
            context: context,
            backgroundColor: c.card,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(
                top: Radius.circular(BergaSizes.sheetRadius),
              ),
            ),
            builder: (sheet) => SafeArea(
              child: Padding(
                padding: BergaSizes.sheetPadding,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Nas suas playlists',
                      style: BergaText.h2.copyWith(color: c.tx),
                    ),
                    for (final p in found)
                      InkWell(
                        onTap: () {
                          Navigator.of(sheet).pop();
                          open(p);
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: BergaSizes.sheetItemPaddingVertical,
                          ),
                          child: Text(
                            p.name,
                            style: BergaText.body.copyWith(color: c.tx),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
        child: Row(
          spacing: 6,
          children: [
            Icon(Icons.check_circle, size: 16, color: c.gr),
            Flexible(
              child: Text(
                label,
                key: const Key('in-playlists'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: BergaText.secondary.copyWith(color: c.gr),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
