import 'dart:async';
import 'dart:io';

import 'package:bergastream/core/platform/app_platform.dart';
import 'package:bergastream/core/storage/key_value_store.dart';
import 'package:bergastream/core/widgets/download_state_icon.dart';
import 'package:bergastream/features/auth/session.dart';
import 'package:bergastream/data/local/database.dart';
import 'package:bergastream/data/models/playlist_models.dart';
import 'package:bergastream/data/repositories/playback_repository.dart';
import 'package:bergastream/features/downloads/download_manager.dart';
import 'package:bergastream/features/downloads/file_fetcher.dart';
import 'package:bergastream/features/player/player_controller.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../app_harness.dart';
import '../../fake_player.dart';

/// Download falso: escreve [size] bytes; pode falhar, entregar arquivo
/// incompleto ou segurar até [gate] liberar.
class FakeFetcher implements FileFetcher {
  int size = 100;
  final failures = <String, int>{};
  final truncated = <String>{};
  Completer<void>? gate;
  int concurrent = 0;
  int maxConcurrent = 0;
  final fetched = <String>[];

  @override
  Future<FetchResult> fetch(
    Uri url,
    String path, {
    String? label,
    void Function(double progress)? onProgress,
  }) async {
    concurrent++;
    maxConcurrent = concurrent > maxConcurrent ? concurrent : maxConcurrent;
    try {
      if (gate != null) await gate!.future;
      final key = url.pathSegments.length > 2 ? url.pathSegments[2] : url.host;
      fetched.add(key);
      if ((failures[key] ?? 0) > 0) {
        failures[key] = failures[key]! - 1;
        throw const SocketException('sem rede');
      }
      final bytes = truncated.contains(key) ? size ~/ 2 : size;
      await File(path).writeAsBytes(List.filled(bytes, 1));
      return FetchResult(bytes: bytes, expectedBytes: size, format: 'mp3');
    } finally {
      concurrent--;
    }
  }
}

class FakeNetwork implements NetworkCheck {
  bool wifi = true;
  final _changes = StreamController<void>.broadcast();
  void change() => _changes.add(null);

  @override
  Future<bool> onWifi() async => wifi;

  @override
  Stream<void> get changes => _changes.stream;
}

PlaylistTrack t(String id, {String? cover = 'https://img/x.jpg'}) =>
    PlaylistTrack(
      trackId: id,
      provider: 'spotify',
      externalId: id,
      title: 'Faixa $id',
      artist: 'A',
      coverUrl: cover,
      addedAt: '2026-10-01',
    );

PlaylistDetail playlist(String id, List<String> ids) => PlaylistDetail(
  id: id,
  name: 'Playlist $id',
  tracks: [for (final x in ids) t(x)],
);

void main() {
  late Directory dir;
  late AppDatabase db;
  late FakeFetcher fetcher;
  late FakeNetwork network;
  late FakePlaybackRepository server;
  late ProviderContainer c;

  DownloadManager manager() => c.read(downloadManagerProvider.notifier);
  Future<LocalTrack?> track(String id) => db.track(id);

  Future<void> settle() async {
    for (var i = 0; i < 30; i++) {
      await pumpEventQueue();
      if (c.read(downloadManagerProvider).active == 0) break;
    }
  }

  ProviderContainer makeContainer() {
    final container = ProviderContainer(
      overrides: [
        localDatabaseProvider.overrideWithValue(db),
        fileFetcherProvider.overrideWithValue(fetcher),
        networkCheckProvider.overrideWithValue(network),
        playbackRepositoryProvider.overrideWithValue(server),
        playerTimingsProvider.overrideWithValue(
          const PlayerTimings(pollInterval: Duration.zero),
        ),
        appPlatformProvider.overrideWithValue(const AppPlatform.app()),
        keyValueStoreProvider.overrideWithValue(MemoryKeyValueStore()),
        initialSessionProvider.overrideWithValue(loggedIn),
        downloadPathsProvider.overrideWithValue(
          () async => DownloadPaths(audio: dir.path, covers: dir.path),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(downloadManagerProvider.notifier).retryBase = Duration.zero;
    return container;
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('downloads');
    db = AppDatabase(NativeDatabase.memory());
    fetcher = FakeFetcher();
    network = FakeNetwork();
    server = FakePlaybackRepository();
    c = makeContainer();
  });

  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  test(
    'baixa áudio e capa; só então marca como baixada com metadados',
    () async {
      await manager().downloadPlaylist(playlist('p1', ['a']));
      await settle();
      final a = (await track('a'))!;
      expect(a.downloadState, DownloadState.baixada);
      expect(File(a.audioPath!).existsSync(), isTrue);
      expect(a.audioPath, endsWith('a.mp3'));
      expect(File(a.coverPath!).existsSync(), isTrue);
      expect(a.sizeBytes, 100);
      expect(a.downloadedAt, isNotNull);
      expect(fetcher.fetched, ['id-a', 'img']);
    },
  );

  test('espera o servidor preparar a faixa antes de baixar', () async {
    server
      ..initial = TrackReadiness.baixando
      ..statuses = [TrackReadiness.baixando, TrackReadiness.pronta];
    await manager().downloadPlaylist(playlist('p1', ['a']));
    await settle();
    expect(server.statusCalls, 2);
    expect((await track('a'))!.downloadState, DownloadState.baixada);
  });

  test('arquivo incompleto não vira baixada; tenta de novo', () async {
    fetcher.truncated.add('id-a');
    await manager().downloadPlaylist(playlist('p1', ['a']));
    await settle();
    final a = (await track('a'))!;
    expect(a.downloadState, DownloadState.falhou);
    expect(a.attempts, DownloadManager.maxAttempts);
    expect(dir.listSync(), isEmpty, reason: 'arquivos parciais apagados');
  });

  test('falha de rede: até 3 tentativas, depois falhou', () async {
    fetcher.failures['id-a'] = 2;
    await manager().downloadPlaylist(playlist('p1', ['a']));
    await settle();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await settle();
    expect((await track('a'))!.downloadState, DownloadState.baixada);

    fetcher.failures['id-b'] = 5;
    await manager().downloadPlaylist(playlist('p2', ['b']));
    for (var i = 0; i < 5; i++) {
      await settle();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final b = (await track('b'))!;
    expect(b.downloadState, DownloadState.falhou);
    expect(fetcher.fetched.where((k) => k == 'id-b'), hasLength(3));
  });

  test('capa que falha impede de marcar como baixada', () async {
    fetcher.failures['img'] = 99;
    await manager().downloadPlaylist(playlist('p1', ['a']));
    for (var i = 0; i < 5; i++) {
      await settle();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect((await track('a'))!.downloadState, DownloadState.falhou);
    expect(dir.listSync(), isEmpty);
  });

  test('no máximo 2 downloads ao mesmo tempo', () async {
    fetcher.gate = Completer<void>();
    await manager().downloadPlaylist(playlist('p1', ['a', 'b', 'c', 'd']));
    await pumpEventQueue();
    expect(c.read(downloadManagerProvider).active, 2);
    fetcher.gate!.complete();
    await settle();
    expect(fetcher.maxConcurrent, lessThanOrEqualTo(2));
    final states = [
      for (final id in 'abcd'.split('')) (await track(id))!.downloadState,
    ];
    expect(states.every((s) => s == DownloadState.baixada), isTrue);
  });

  test('retoma depois de reiniciar o app', () async {
    await db.savePlaylist(playlist('p1', ['a', 'b']));
    // "baixando" quando o app fechou.
    await db.updateTrack(
      'a',
      const LocalTracksCompanion(downloadState: Value(DownloadState.baixando)),
    );
    c.dispose();
    c = makeContainer();
    await manager().start();
    await settle();
    expect((await track('a'))!.downloadState, DownloadState.baixada);
    expect((await track('b'))!.downloadState, DownloadState.baixada);
  });

  test('"só no Wi-Fi": espera o Wi-Fi e continua quando conecta', () async {
    network.wifi = false;
    await manager().start();
    await manager().downloadPlaylist(playlist('p1', ['a']));
    await settle();
    expect(c.read(downloadManagerProvider).waitingForWifi, isTrue);
    expect((await track('a'))!.downloadState, DownloadState.naFila);
    network
      ..wifi = true
      ..change();
    await settle();
    expect((await track('a'))!.downloadState, DownloadState.baixada);
  });

  test('desligar "só no Wi-Fi" baixa nos dados móveis', () async {
    network.wifi = false;
    await db.setStateValue(wifiOnlyKey, 'false');
    await manager().downloadPlaylist(playlist('p1', ['a']));
    await settle();
    expect((await track('a'))!.downloadState, DownloadState.baixada);
  });

  test(
    'remover download apaga só arquivos que nenhuma outra playlist usa',
    () async {
      await manager().downloadPlaylist(playlist('p1', ['a', 'b']));
      await manager().downloadPlaylist(playlist('p2', ['b']));
      await settle();
      final a = (await track('a'))!;
      final b = (await track('b'))!;
      await manager().removeDownload('p1');
      expect(File(a.audioPath!).existsSync(), isFalse);
      expect(File(b.audioPath!).existsSync(), isTrue);
      await manager().removeAll();
      expect(File(b.audioPath!).existsSync(), isFalse);
      expect(await db.usedBytes(), 0);
    },
  );

  test('pausar segura a fila; continuar retoma', () async {
    fetcher.gate = Completer<void>();
    await manager().downloadPlaylist(playlist('p1', ['a', 'b', 'c']));
    await pumpEventQueue();
    await manager().pause('p1');
    fetcher.gate!.complete();
    await settle();
    expect((await track('c'))!.downloadState, DownloadState.naFila);
    await manager().resume('p1');
    await settle();
    expect((await track('c'))!.downloadState, DownloadState.baixada);
  });

  test('sem servidor não baixa; ao voltar, continua', () async {
    c.read(sessionProvider.notifier).setServerAvailable(false);
    await manager().downloadPlaylist(playlist('p1', ['a']));
    await settle();
    expect((await track('a'))!.downloadState, DownloadState.naFila);
    c.read(sessionProvider.notifier).setServerAvailable(true);
    await settle();
    expect((await track('a'))!.downloadState, DownloadState.baixada);
  });
}
