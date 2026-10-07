import 'dart:io';

import 'package:bergastream/core/platform/app_platform.dart';
import 'package:bergastream/core/storage/key_value_store.dart';
import 'package:bergastream/core/theme/berga_theme.dart';
import 'package:bergastream/data/repositories/auth_repository.dart';
import 'package:bergastream/data/repositories/fake_auth_repository.dart';
import 'package:bergastream/data/local/database.dart';
import 'package:bergastream/data/repositories/catalog_repository.dart';
import 'package:bergastream/data/repositories/history_repository.dart';
import 'package:bergastream/features/downloads/download_manager.dart';
import 'package:bergastream/features/downloads/file_fetcher.dart';
import 'package:bergastream/features/sync/server_monitor.dart';
import 'package:drift/native.dart';
import 'package:bergastream/data/repositories/playback_repository.dart';
import 'package:bergastream/data/repositories/playlist_repository.dart';
import 'package:bergastream/data/repositories/search_repository.dart';
import 'package:bergastream/features/player/audio_engine.dart';
import 'package:bergastream/features/player/player_controller.dart';
import 'package:bergastream/features/auth/session.dart';
import 'package:bergastream/features/update/update_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_harness.dart';
import 'fake_player.dart';
import 'fake_update.dart';

/// Envolve [child] em um app com o tema do Bergastream (escuro por padrão)
/// e uma sessão logada fictícia.
Widget wrap(
  Widget child, {
  ThemeData? theme,
  SessionState session = loggedIn,
  AppPlatform platform = const AppPlatform.app(),
  SearchRepository? search,
  AudioEngine? engine,
  PlaybackRepository? playback,
  PlaylistRepository? playlists,
  CatalogRepository? catalog,
  AppDatabase? db,
  FileFetcher? fetcher,
  HistoryRepository? history,
  ServerPing? ping,
  UpdateTarget? updateTarget,
  FakeUpdateRepository? updates,
  FakeUpdateLauncher? launcher,
}) {
  return ProviderScope(
    overrides: [
      appPlatformProvider.overrideWithValue(platform),
      updateTargetProvider.overrideWithValue(updateTarget),
      updateRepositoryProvider.overrideWithValue(
        updates ?? FakeUpdateRepository(),
      ),
      updateLauncherProvider.overrideWithValue(
        launcher ?? FakeUpdateLauncher(),
      ),
      keyValueStoreProvider.overrideWithValue(MemoryKeyValueStore()),
      initialSessionProvider.overrideWithValue(session),
      authRepositoryProvider.overrideWithValue(
        FakeAuthRepository(delay: Duration.zero),
      ),
      searchRepositoryProvider.overrideWithValue(
        search ?? FakeSearchRepository(),
      ),
      audioEngineProvider.overrideWithValue(engine ?? FakeAudioEngine()),
      playbackRepositoryProvider.overrideWithValue(
        playback ?? FakePlaybackRepository(),
      ),
      playlistRepositoryProvider.overrideWithValue(
        playlists ?? FakePlaylistRepository(),
      ),
      historyRepositoryProvider.overrideWithValue(
        history ?? FakeHistoryRepository(statsValue: sampleStats),
      ),
      catalogRepositoryProvider.overrideWithValue(
        catalog ?? FakeCatalogRepository(),
      ),
      localDatabaseProvider.overrideWithValue(
        db ?? (platform.isApp && !platform.simulated ? _memoryDb() : null),
      ),
      fileFetcherProvider.overrideWithValue(fetcher ?? _NoFetcher()),
      networkCheckProvider.overrideWithValue(_AlwaysWifi()),
      serverPingProvider.overrideWithValue(ping ?? (_) async => true),
      connectivityChangesProvider.overrideWithValue(const Stream.empty()),
      serverRetryIntervalProvider.overrideWithValue(null),
      downloadPathsProvider.overrideWithValue(
        () async => DownloadPaths(
          audio: Directory.systemTemp.path,
          covers: Directory.systemTemp.path,
        ),
      ),
      playerTimingsProvider.overrideWithValue(
        const PlayerTimings(pollInterval: Duration.zero),
      ),
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme ?? BergaTheme.dark,
      home: Scaffold(body: child),
    ),
  );
}

AppDatabase _memoryDb() => AppDatabase(NativeDatabase.memory());

class _NoFetcher implements FileFetcher {
  @override
  Future<FetchResult> fetch(
    Uri url,
    String path, {
    String? label,
    void Function(double progress)? onProgress,
  }) => throw UnimplementedError('download inesperado no teste');
}

class _AlwaysWifi implements NetworkCheck {
  @override
  Future<bool> onWifi() async => true;

  @override
  Stream<void> get changes => const Stream.empty();
}
