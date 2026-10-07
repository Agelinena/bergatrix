import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../data/models/search_result.dart';
import 'routes.dart';

/// Caminho atual do router (funciona também de folhas e do player grande).
String currentPath(BuildContext context) =>
    GoRouter.of(context).routerDelegate.currentConfiguration.uri.path;

void openArtist(BuildContext context, String provider, String id) =>
    context.push(AppRoutes.artistOf(currentPath(context), provider, id));

void openAlbum(BuildContext context, String provider, String id) =>
    context.push(AppRoutes.albumOf(currentPath(context), provider, id));

/// "Ir para o artista" de uma faixa, ou nulo se a origem não informa.
VoidCallback? goToArtistOf(BuildContext context, SearchResult t) =>
    t.hasCatalogPages && t.artistId != null
    ? () => openArtist(context, t.provider, t.artistId!)
    : null;

/// "Ir para o álbum" de uma faixa, ou nulo se a origem não informa.
VoidCallback? goToAlbumOf(BuildContext context, SearchResult t) =>
    t.hasCatalogPages && t.albumId != null
    ? () => openAlbum(context, t.provider, t.albumId!)
    : null;

/// Caminho da página do álbum/artista da faixa (para navegar depois de
/// fechar uma rota, quando o `context` atual já não vale).
String? albumPathOf(BuildContext context, SearchResult t) =>
    t.hasCatalogPages && t.albumId != null
    ? AppRoutes.albumOf(currentPath(context), t.provider, t.albumId!)
    : null;

String? artistPathOf(BuildContext context, SearchResult t) =>
    t.hasCatalogPages && t.artistId != null
    ? AppRoutes.artistOf(currentPath(context), t.provider, t.artistId!)
    : null;
