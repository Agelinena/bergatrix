import 'dart:io';

import 'package:bergastream/app/app.dart';
import 'package:bergastream/app/router.dart';
import 'package:bergastream/app/routes.dart';
import 'package:bergastream/core/platform/app_platform.dart';
import 'package:bergastream/core/storage/key_value_store.dart';
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
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:bergastream/data/models/stats.dart';
import 'package:bergastream/data/repositories/fake_catalog.dart';
import 'package:bergastream/data/repositories/server_status_repository.dart';
import 'package:bergastream/features/update/update_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_player.dart';
import 'fake_update.dart';

const testServer = 'https://musica.exemplo.com';

const loggedIn = SessionState(
  status: SessionStatus.logado,
  server: testServer,
  username: 'demo',
);

const noServer = SessionState(status: SessionStatus.semServidorConfigurado);

/// Monta o app completo com plataforma, sessão e repositório fictícios.
/// Devolve o container para os testes lerem o estado.
Future<ProviderContainer> pumpBergastream(
  WidgetTester tester, {
  AppPlatform platform = const AppPlatform.app(),
  SessionState session = loggedIn,
  Size size = const Size(360, 800),
  String initialLocation = AppRoutes.home,
  FakeAuthRepository? auth,
  KeyValueStore? store,
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
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final container = ProviderContainer(
    overrides: [
      appPlatformProvider.overrideWithValue(platform),
      serverStatusRepositoryProvider.overrideWithValue(
        FakeServerStatusRepository(),
      ),
      serverStatusRefreshProvider.overrideWithValue(null),
      updateTargetProvider.overrideWithValue(updateTarget),
      updateRepositoryProvider.overrideWithValue(
        updates ?? FakeUpdateRepository(),
      ),
      updateLauncherProvider.overrideWithValue(
        launcher ?? FakeUpdateLauncher(),
      ),
      keyValueStoreProvider.overrideWithValue(store ?? MemoryKeyValueStore()),
      initialSessionProvider.overrideWithValue(session),
      initialLocationProvider.overrideWithValue(initialLocation),
      authRepositoryProvider.overrideWithValue(
        auth ?? FakeAuthRepository(delay: Duration.zero),
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
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const BergastreamApp(),
    ),
  );
  await settleDb(tester);
  return container;
}

/// Banco em memória. Não é fechado: o `close()` do Drift trava no relógio
/// falso dos testes de tela (o banco some com o teste).
AppDatabase _memoryDb() => AppDatabase(NativeDatabase.memory());

/// Consultas reativas do Drift usam timers que o `pumpAndSettle` não
/// dispara quando nenhum quadro está agendado: avança o tempo aos poucos.
Future<void> settleDb(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  await tester.pumpAndSettle();
}

/// Download que nunca deveria ser chamado nos testes de tela.
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

/// Métricas no estilo do protótipo ("42 h", "318").
final sampleStats = ListeningStats(
  month: '2026-10',
  secondsMonth: 42 * 3600,
  distinctTracksMonth: 318,
  playsMonth: 900,
  topArtists: [
    for (final a in FakeCatalog.topArtists) StatArtist(name: a, plays: 10),
  ],
  topTracks: [
    for (final i in [0, 2, 5, 7])
      StatTrack(
        track: FakeSearchRepository.trackOf(i, SearchSource.spotify),
        plays: 5,
      ),
  ],
  topAlbums: [
    for (final t in FakeCatalog.topAlbums)
      StatAlbum(title: t.album, artist: t.artist, plays: 3),
  ],
);
