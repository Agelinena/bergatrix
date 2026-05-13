import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../providers/auth_provider.dart';
import '../../screens/auth/login_screen.dart';
import '../../screens/auth/register_screen.dart';
import '../../screens/home/home_screen.dart';
import '../../screens/search/search_screen.dart';
import '../../screens/library/library_screen.dart';
import '../../screens/playlist/playlist_screen.dart';
import '../../screens/album/album_screen.dart';
import '../../screens/artist/artist_screen.dart';
import '../../screens/history/history_screen.dart';
import '../../screens/radio/radio_screen.dart';
import '../../screens/settings/settings_screen.dart';
import '../../widgets/layout/main_scaffold.dart';

part 'app_router.g.dart';

@riverpod
GoRouter appRouter(AppRouterRef ref) {
  final auth = ref.watch(authProvider);

  return GoRouter(
    initialLocation: '/',
    redirect: (context, state) {
      final isAuth = auth.valueOrNull != null;
      final isAuthRoute = state.matchedLocation.startsWith('/login') ||
          state.matchedLocation.startsWith('/register');

      if (auth.isLoading) return null;
      if (!isAuth && !isAuthRoute) return '/login';
      if (isAuth && isAuthRoute) return '/';
      return null;
    },
    routes: [
      GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),
      GoRoute(path: '/register', builder: (_, __) => const RegisterScreen()),
      ShellRoute(
        builder: (context, state, child) => MainScaffold(child: child),
        routes: [
          GoRoute(path: '/', builder: (_, __) => const HomeScreen()),
          GoRoute(path: '/search', builder: (_, __) => const SearchScreen()),
          GoRoute(path: '/library', builder: (_, __) => const LibraryScreen()),
          GoRoute(
            path: '/playlist/:id',
            builder: (_, state) => PlaylistScreen(id: state.pathParameters['id']!),
          ),
          GoRoute(
            path: '/album/:id',
            builder: (_, state) => AlbumScreen(id: state.pathParameters['id']!),
          ),
          GoRoute(
            path: '/artist/:id',
            builder: (_, state) => ArtistScreen(id: state.pathParameters['id']!),
          ),
          GoRoute(path: '/history', builder: (_, __) => const HistoryScreen()),
          GoRoute(path: '/settings', builder: (_, __) => const SettingsScreen()),
          GoRoute(
            path: '/shared/:token',
            builder: (_, state) => const LibraryScreen(), // placeholder — redireciona para follow
          ),
        ],
      ),
    ],
  );
}
