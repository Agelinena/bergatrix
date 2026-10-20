import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/catalog_navigation.dart';
import '../../app/routes.dart';
import '../../data/models/search_result.dart';
import 'player_texts.dart';

/// "Artista · Álbum" do que está tocando, com cada nome clicável: abre a
/// página do artista/álbum quando a origem informa o id; senão, a busca
/// pelo nome (faixas de playlist não guardam os ids do catálogo).
class ArtistAlbumLinks extends StatelessWidget {
  const ArtistAlbumLinks({
    super.key,
    required this.track,
    required this.style,
    this.beforeNavigate,
  });

  final SearchResult track;
  final TextStyle style;

  /// Antes de navegar (ex.: fechar o player grande). Recebe o router
  /// capturado antes, porque o `context` pode deixar de valer.
  final void Function()? beforeNavigate;

  void _open(BuildContext context, String? catalogPath, String searchTerm) {
    final router = GoRouter.of(context);
    beforeNavigate?.call();
    if (catalogPath != null) {
      router.push(catalogPath);
    } else {
      router.go(
        '${AppRoutes.search}?q=${Uri.encodeQueryComponent(searchTerm)}',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final artist = track.artist;
    final album = track.album;
    if (artist.isEmpty && album.isEmpty) {
      return Text(artistAndAlbum(track), style: style);
    }
    Widget link(String text, VoidCallback onTap) => Flexible(
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
      ),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (artist.isNotEmpty)
          link(
            artist,
            () => _open(context, artistPathOf(context, track), artist),
          ),
        if (artist.isNotEmpty && album.isNotEmpty) Text(' · ', style: style),
        if (album.isNotEmpty)
          link(
            album,
            () => _open(context, albumPathOf(context, track), '$album $artist'),
          ),
      ],
    );
  }
}
