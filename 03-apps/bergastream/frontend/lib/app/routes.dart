/// Caminhos das telas.
abstract final class AppRoutes {
  static const login = '/entrar';
  static const home = '/inicio';
  static const search = '/buscar';
  static const library = '/biblioteca';
  static const settings = '/ajustes';

  /// Gerenciar downloads (Ajustes).
  static const manageDownloads = '$settings/downloads';

  /// Detalhe da playlist do servidor, "Pessoas" e playlist local.
  static String playlist(String id) => '$library/playlist/$id';
  static String playlistPeople(String id) => '$library/playlist/$id/pessoas';
  static String localPlaylist(String id) => '$library/local/$id';

  /// Playlist/álbum de link colado: `/buscar/link?url=...`.
  static String importedLink(String url) =>
      '$search/link?url=${Uri.encodeQueryComponent(url)}';

  /// Artista e álbum (Seção 6.7) abrem dentro da aba atual, para manter a
  /// barra de navegação e o player: `/buscar/artista/spotify/<id>`.
  static String artistOf(String currentPath, String provider, String id) =>
      '${tabOf(currentPath)}/artista/$provider/${Uri.encodeComponent(id)}';
  static String albumOf(String currentPath, String provider, String id) =>
      '${tabOf(currentPath)}/album/$provider/${Uri.encodeComponent(id)}';

  /// Aba de um caminho (`/buscar/link` → `/buscar`). Ajustes não tem
  /// páginas de catálogo: cai em Início.
  static String tabOf(String path) {
    for (final tab in [home, search, library]) {
      if (path == tab || path.startsWith('$tab/')) return tab;
    }
    return home;
  }

  /// Galeria de componentes (só em debug).
  static const gallery = '/dev/gallery';
}
