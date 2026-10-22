import 'dart:io';

import 'package:bergastream/core/platform/app_platform.dart';
import 'package:bergastream/core/storage/key_value_store.dart';
import 'package:bergastream/data/repositories/auth_repository.dart';
import 'package:bergastream/data/repositories/fake_auth_repository.dart';
import 'package:bergastream/data/repositories/local_playlists.dart';
import 'package:bergastream/features/auth/session.dart';
import 'package:bergastream/features/downloads/download_manager.dart';
import 'package:bergastream/features/downloads/file_fetcher.dart';
import 'package:bergastream/features/library/playlist_cover.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../app_harness.dart';

class _CoverFetcher implements FileFetcher {
  final urls = <String>[];

  @override
  Future<FetchResult> fetch(
    Uri url,
    String path, {
    String? label,
    void Function(double progress)? onProgress,
  }) async {
    urls.add('$url');
    await File(path).writeAsBytes([1, 2, 3]);
    return const FetchResult(bytes: 3);
  }
}

void main() {
  late Directory dir;
  late _CoverFetcher fetcher;

  ProviderContainer create() {
    final c = ProviderContainer(
      overrides: [
        appPlatformProvider.overrideWithValue(const AppPlatform.app()),
        keyValueStoreProvider.overrideWithValue(MemoryKeyValueStore()),
        initialSessionProvider.overrideWithValue(loggedIn),
        authRepositoryProvider.overrideWithValue(
          FakeAuthRepository(delay: Duration.zero),
        ),
        downloadPathsProvider.overrideWithValue(
          () async => DownloadPaths(audio: dir.path, covers: dir.path),
        ),
        coverFetcherProvider.overrideWithValue(fetcher),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('capas');
    fetcher = _CoverFetcher();
    addTearDown(() => dir.deleteSync(recursive: true));
  });

  Future<String?> cover(ProviderContainer c, String version) => c.read(
    playlistCoverFileProvider((
      id: 'p1',
      url: '/api/playlists/p1/cover?v=$version',
    )).future,
  );

  test('guarda a foto da playlist e usa a cópia depois', () async {
    final path = await cover(create(), '1');
    expect(path, endsWith('playlist-p1-1.img'));
    expect(File(path!).existsSync(), isTrue);
    expect(fetcher.urls, ['$testServer/api/playlists/p1/cover?v=1']);

    // Abrindo de novo: não baixa outra vez.
    expect(await cover(create(), '1'), path);
    expect(fetcher.urls, hasLength(1));
  });

  test('sem servidor usa a última foto; com servidor troca', () async {
    final first = await cover(create(), '1');
    final offline = create();
    offline.read(sessionProvider.notifier).setServerAvailable(false);
    expect(await cover(offline, '2'), first);

    final second = await cover(create(), '2');
    expect(second, endsWith('playlist-p1-2.img'));
    expect(File(first!).existsSync(), isFalse, reason: 'a antiga sai');
  });

  test('playlist local: foto guardada e apagada junto', () async {
    final c = create();
    final notifier = c.read(localPlaylistsProvider.notifier);
    await notifier.loaded;
    final p = await notifier.create('Viagem');
    await notifier.setCover(p.id, [9, 9]);
    final path = c.read(localPlaylistsProvider).single.coverPath!;
    expect(File(path).readAsBytesSync(), [9, 9]);
    expect(
      localPlaylistImage(c.read(localPlaylistsProvider).single),
      isNotNull,
    );

    await notifier.delete(p.id);
    expect(File(path).existsSync(), isFalse);
  });
}
