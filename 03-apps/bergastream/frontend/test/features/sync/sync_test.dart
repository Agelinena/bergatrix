import 'dart:async';
import 'dart:convert';

import 'package:bergastream/core/platform/app_platform.dart';
import 'package:bergastream/core/storage/key_value_store.dart';
import 'package:bergastream/core/widgets/download_state_icon.dart';
import 'package:bergastream/data/local/database.dart';
import 'package:bergastream/data/models/playlist_models.dart';
import 'package:bergastream/data/repositories/history_repository.dart';
import 'package:bergastream/data/repositories/playback_repository.dart';
import 'package:bergastream/data/repositories/playlist_repository.dart';
import 'package:bergastream/features/auth/session.dart';
import 'package:bergastream/features/downloads/download_manager.dart';
import 'package:bergastream/features/downloads/file_fetcher.dart';
import 'package:bergastream/features/player/player_controller.dart';
import 'package:bergastream/features/sync/server_monitor.dart';
import 'package:bergastream/features/sync/sync_service.dart';
import 'package:bergastream/data/api/api_dio.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../app_harness.dart';
import '../../fake_http.dart' show FakeAdapter;
import '../../fake_player.dart';

/// Servidor de playlists em que dá para mudar a playlist p1 "pelo web".
class ChangingPlaylists extends FakePlaylistRepository {
  String updatedAt = 'v1';

  @override
  Future<List<ServerPlaylist>> myPlaylists() async => [
    ServerPlaylist(id: 'p1', name: 'Roadtrip', updatedAt: updatedAt),
  ];

  @override
  Future<PlaylistDetail> detail(String id) async {
    final d = await super.detail(id);
    return PlaylistDetail(
      id: d.id,
      name: d.name,
      owner: d.owner,
      updatedAt: updatedAt,
      tracks: d.tracks,
    );
  }
}

class NoFetch implements FileFetcher {
  @override
  Future<FetchResult> fetch(
    Uri url,
    String path, {
    String? label,
    void Function(double progress)? onProgress,
  }) => Completer<FetchResult>().future; // fica "baixando" (não importa aqui)
}

void main() {
  late AppDatabase db;
  late FakeHistoryRepository history;
  late ChangingPlaylists playlists;
  late ProviderContainer c;
  late bool pingOk;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    history = FakeHistoryRepository();
    playlists = ChangingPlaylists();
    pingOk = true;
    c = ProviderContainer(
      overrides: [
        appPlatformProvider.overrideWithValue(const AppPlatform.app()),
        keyValueStoreProvider.overrideWithValue(MemoryKeyValueStore()),
        initialSessionProvider.overrideWithValue(loggedIn),
        localDatabaseProvider.overrideWithValue(db),
        historyRepositoryProvider.overrideWithValue(history),
        playlistRepositoryProvider.overrideWithValue(playlists),
        playbackRepositoryProvider.overrideWithValue(FakePlaybackRepository()),
        fileFetcherProvider.overrideWithValue(NoFetch()),
        networkCheckProvider.overrideWithValue(_Wifi()),
        playerTimingsProvider.overrideWithValue(
          const PlayerTimings(
            pollInterval: Duration.zero,
            rapidChangeDelay: Duration.zero,
          ),
        ),
        serverPingProvider.overrideWithValue((_) async => pingOk),
        connectivityChangesProvider.overrideWithValue(const Stream.empty()),
        downloadPathsProvider.overrideWithValue(
          () async => const DownloadPaths(audio: '/tmp', covers: '/tmp'),
        ),
      ],
    );
    addTearDown(c.dispose);
    addTearDown(db.close);
  });

  Future<void> addPending(PlayRecord p) =>
      db.addPendingPlay(jsonEncode(p.toJson()), p.playedAt);

  PlayRecord play(String title, int minute, {String? id}) => PlayRecord(
    track: song(title),
    playedAt: DateTime(2026, 10, 7, 10, minute),
    clientId: id,
  );

  group('reproduções pendentes', () {
    test('enviadas na ordem, sem duplicar, e apagadas do aparelho', () async {
      await addPending(play('A', 1, id: 'x1'));
      await addPending(play('B', 2));
      await addPending(play('A', 1, id: 'x1')); // a mesma reenviada
      await addPending(play('C', 3));
      final sent = await c
          .read(syncServiceProvider.notifier)
          .sendPendingPlays();
      expect(sent, 4);
      expect([for (final p in history.sent) p.track.title], ['A', 'B', 'C']);
      expect(await db.pendingPlaysInOrder(), isEmpty);
    });

    test('se o servidor falha, continuam guardadas', () async {
      history.failing = true;
      await addPending(play('A', 1));
      expect(await c.read(syncServiceProvider.notifier).sendPendingPlays(), 0);
      expect(await db.pendingPlaysInOrder(), hasLength(1));
    });

    test('vão ao reconectar', () async {
      c.read(syncServiceProvider);
      c.read(sessionProvider.notifier).setServerAvailable(false);
      await addPending(play('A', 1));
      c.read(sessionProvider.notifier).setServerAvailable(true);
      await pumpEventQueue();
      expect(history.sent, hasLength(1));
    });
  });

  group('playlist baixada que mudou no servidor', () {
    Future<void> download() async {
      await db.savePlaylist(await playlists.detail('p1'));
      for (final id in ['tr0', 'tr1', 'tr2', 'tr3', 'tr4']) {
        await db.updateTrack(
          id,
          const LocalTracksCompanion(
            downloadState: Value(DownloadState.baixada),
          ),
        );
      }
      await db.setPaused('p1', true);
    }

    test('conta novas e removidas (selo)', () async {
      await download();
      playlists.tracks
        ..removeAt(1)
        ..add(playlists.tracks.first.copyForTest('novaA'))
        ..add(playlists.tracks.first.copyForTest('novaB'));
      final changes = await compareWithDownload(
        db,
        await playlists.detail('p1'),
      );
      expect((changes.added, changes.removed), (2, 1));
    });

    test('atualizar: baixa as novas, libera as retiradas', () async {
      await download();
      playlists.updatedAt = 'v2';
      playlists.tracks
        ..removeAt(1) // tr1 saiu
        ..add(playlists.tracks.first.copyForTest('nova'));
      final updated = await c
          .read(syncServiceProvider.notifier)
          .updateDownloadedPlaylists();
      expect(updated, 1);
      expect(await db.track('tr1'), isNull, reason: 'retirada liberada');
      expect(
        (await db.track('nova'))!.downloadState,
        isNot(DownloadState.baixada),
      );
      expect((await db.playlist('p1'))!.serverUpdatedAt, 'v2');
      // Sem mudança nova: nada a fazer.
      expect(
        await c.read(syncServiceProvider.notifier).updateDownloadedPlaylists(),
        0,
      );
    });
  });

  group('detecção do servidor', () {
    test('falha de conexão marca indisponível; ping OK volta', () async {
      final monitor = c.read(serverMonitorProvider.notifier);
      monitor.reportFailure();
      expect(c.read(sessionProvider).serverAvailable, isFalse);
      pingOk = false;
      expect(await monitor.check(), isFalse);
      expect(c.read(sessionProvider).serverAvailable, isFalse);
      pingOk = true;
      expect(await monitor.check(), isTrue);
      expect(c.read(sessionProvider).serverAvailable, isTrue);
    });

    test(
      '502 do proxy (API fora) confere o /health e marca indisponível',
      () async {
        pingOk = false;
        final dio = c.read(apiDioProvider)
          ..httpClientAdapter = FakeAdapter(
            // Como o nginx responde: HTML com 502.
            (_) async => ResponseBody.fromString(
              '<html>502 Bad Gateway</html>',
              502,
              headers: {
                Headers.contentTypeHeader: ['text/html'],
              },
            ),
          );
        await expectLater(
          dio.get<dynamic>('/api/search'),
          throwsA(isA<DioException>()),
        );
        await pumpEventQueue();
        expect(c.read(sessionProvider).serverAvailable, isFalse);
      },
    );

    test('sem login não marca nada', () async {
      final c2 = ProviderContainer(
        overrides: [
          appPlatformProvider.overrideWithValue(const AppPlatform.app()),
          keyValueStoreProvider.overrideWithValue(MemoryKeyValueStore()),
          initialSessionProvider.overrideWithValue(noServer),
        ],
      );
      addTearDown(c2.dispose);
      c2.read(serverMonitorProvider.notifier).reportFailure();
      expect(c2.read(sessionProvider).serverAvailable, isTrue);
    });
  });
}

class _Wifi implements NetworkCheck {
  @override
  Future<bool> onWifi() async => true;

  @override
  Stream<void> get changes => const Stream.empty();
}

extension on PlaylistTrack {
  PlaylistTrack copyForTest(String id) => PlaylistTrack(
    trackId: id,
    provider: 'spotify',
    externalId: id,
    title: 'Faixa $id',
    artist: artist,
    addedAt: addedAt,
  );
}
