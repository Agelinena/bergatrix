import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/platform/app_platform.dart';
import '../features/album/album_screen.dart';
import '../features/artist/artist_screen.dart';
import '../features/auth/access_redirect.dart';
import '../features/downloads/manage_downloads_screen.dart';
import '../features/auth/login_screen.dart';
import '../features/auth/session.dart';
import '../features/home/home_screen.dart';
import '../features/library/library_screen.dart';
import '../features/library/local_playlist_screen.dart';
import '../features/library/people_screen.dart';
import '../features/library/playlist_screen.dart';
import '../features/search/imported_link_screen.dart';
import '../features/search/search_screen.dart';
import '../features/settings/settings_screen.dart';
import 'app_shell.dart';
import 'dev/gallery_screen.dart';
import 'not_found_screen.dart';
import 'routes.dart';

/// Tela em que o app abre (os testes podem trocar).
final initialLocationProvider = Provider<String>((ref) => AppRoutes.home);

/// Router com as 4 abas num shell (troca de aba preserva rolagem e estado)
/// e redirecionamento conforme a sessão (Seção 2.3).
final routerProvider = Provider<GoRouter>((ref) {
  final refresh = ValueNotifier(0);
  ref.listen(sessionProvider, (_, _) => refresh.value++);

  // Artista e álbum abrem dentro da aba atual (mantêm navegação e player).
  List<GoRoute> catalog() => [
    GoRoute(
      path: 'artista/:provider/:id',
      builder: (_, s) => ArtistScreen(
        provider: s.pathParameters['provider']!,
        id: s.pathParameters['id']!,
      ),
    ),
    GoRoute(
      path: 'album/:provider/:id',
      builder: (_, s) => AlbumScreen(
        provider: s.pathParameters['provider']!,
        id: s.pathParameters['id']!,
      ),
    ),
  ];

  GoRoute tab(String path, Widget Function() screen) => GoRoute(
    path: path,
    builder: (_, _) => screen(),
    routes: path == AppRoutes.settings
        ? [
            GoRoute(
              path: 'downloads',
              builder: (_, _) => const ManageDownloadsScreen(),
            ),
          ]
        : catalog(),
  );

  final router = GoRouter(
    initialLocation: ref.read(initialLocationProvider),
    refreshListenable: refresh,
    redirect: (_, state) => accessRedirect(
      session: ref.read(sessionProvider),
      isWeb: ref.read(appPlatformProvider).isWeb,
      location: state.matchedLocation,
      loginRoute: AppRoutes.login,
      homeRoute: AppRoutes.home,
      publicRoutes: {if (kDebugMode) AppRoutes.gallery},
    ),
    errorBuilder: (_, _) => const NotFoundScreen(),
    routes: [
      // `#/` (hash vazio) e a raiz do site abrem o Início.
      GoRoute(path: '/', redirect: (_, _) => AppRoutes.home),
      GoRoute(path: AppRoutes.login, builder: (_, _) => const LoginScreen()),
      StatefulShellRoute.indexedStack(
        builder: (_, _, navigationShell) =>
            AppShell(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(
            routes: [tab(AppRoutes.home, () => const HomeScreen())],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.search,
                builder: (_, state) => SearchScreen(
                  initialLink: state.uri.queryParameters['link'],
                  initialQuery: state.uri.queryParameters['q'],
                ),
                routes: [
                  ...catalog(),
                  GoRoute(
                    path: 'link',
                    builder: (_, state) => ImportedLinkScreen(
                      url: state.uri.queryParameters['url'] ?? '',
                    ),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.library,
                builder: (_, _) => const LibraryScreen(),
                routes: [
                  ...catalog(),
                  GoRoute(
                    path: 'playlist/:id',
                    builder: (_, s) =>
                        PlaylistScreen(id: s.pathParameters['id']!),
                    routes: [
                      GoRoute(
                        path: 'pessoas',
                        builder: (_, s) =>
                            PeopleScreen(id: s.pathParameters['id']!),
                      ),
                    ],
                  ),
                  GoRoute(
                    path: 'local/:id',
                    builder: (_, s) =>
                        LocalPlaylistScreen(id: s.pathParameters['id']!),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [tab(AppRoutes.settings, () => const SettingsScreen())],
          ),
        ],
      ),
      if (kDebugMode)
        GoRoute(
          path: AppRoutes.gallery,
          builder: (_, _) => const GalleryScreen(),
        ),
    ],
  );
  ref.onDispose(() {
    router.dispose();
    refresh.dispose();
  });
  return router;
});
