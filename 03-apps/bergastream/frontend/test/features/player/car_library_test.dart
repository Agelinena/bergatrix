import 'package:audio_service/audio_service.dart';
import 'package:bergastream/core/platform/app_platform.dart';
import 'package:bergastream/core/storage/key_value_store.dart';
import 'package:bergastream/data/local/database.dart';
import 'package:bergastream/data/models/playlist_models.dart';
import 'package:bergastream/data/repositories/playback_repository.dart';
import 'package:bergastream/data/repositories/radio_repository.dart';
import 'package:bergastream/data/repositories/search_repository.dart';
import 'package:bergastream/features/auth/session.dart';
import 'package:bergastream/features/player/audio_engine.dart';
import 'package:bergastream/features/player/car_library.dart';
import 'package:bergastream/features/player/player_controller.dart';
import 'package:bergastream/features/playlists/playlist_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../app_harness.dart';
import '../../fake_player.dart';

PlaylistTrack track(String title) => PlaylistTrack(
  trackId: 't-$title',
  provider: 'deezer',
  externalId: title,
  title: title,
  artist: 'Banda',
  coverUrl: 'https://img/$title.jpg',
  addedAt: '2026-01-01T00:00:00Z',
);

final rock = PlaylistDetail(
  id: 'p1',
  name: 'Rock in Metal',
  tracks: [track('A'), track('B'), track('C')],
);

final libraryProvider = Provider((ref) => CarLibrary(ref));

void main() {
  late ProviderContainer container;
  late FakeAudioEngine engine;

  setUp(() {
    engine = FakeAudioEngine();
    container = ProviderContainer(
      overrides: [
        audioEngineProvider.overrideWithValue(engine),
        playbackRepositoryProvider.overrideWithValue(FakePlaybackRepository()),
        radioRepositoryProvider.overrideWithValue(FakeRadioRepository()),
        searchRepositoryProvider.overrideWithValue(FakeSearchRepository()),
        playerTimingsProvider.overrideWithValue(
          const PlayerTimings(
            pollInterval: Duration.zero,
            rapidChangeDelay: Duration.zero,
            autoSkipDelay: Duration.zero,
            radioDelay: Duration.zero,
            fades: false,
          ),
        ),
        playRecorderProvider.overrideWithValue((t, {playlistId}) {}),
        localDatabaseProvider.overrideWithValue(null),
        appPlatformProvider.overrideWithValue(const AppPlatform.app()),
        keyValueStoreProvider.overrideWithValue(MemoryKeyValueStore()),
        initialSessionProvider.overrideWithValue(loggedIn),
        myPlaylistsProvider.overrideWith(
          (ref) async => const [
            ServerPlaylist(
              id: 'p1',
              name: 'Rock in Metal',
              trackCount: 3,
              coverUrl: '/api/playlists/p1/cover?v=1',
            ),
          ],
        ),
        playlistDetailProvider.overrideWith((ref, id) async => rock),
      ],
    );
    addTearDown(container.dispose);
    container.read(playerProvider);
  });

  CarLibrary car() => container.read(libraryProvider);

  test('no carro: Playlists → playlists com capa → músicas', () async {
    final root = await car().children(AudioService.browsableRootId);
    expect(root.single.title, 'Playlists');
    expect(root.single.playable, isFalse);

    final lists = await car().children(CarLibrary.playlists);
    expect(lists.single.title, 'Rock in Metal');
    expect(
      lists.single.artUri.toString(),
      '${loggedIn.server}/api/playlists/p1/cover?v=1',
      reason: 'capa com o endereço do servidor',
    );

    final songs = await car().children(lists.single.id);
    expect(songs.map((s) => s.title), ['A', 'B', 'C']);
    expect(songs.first.playable, isTrue);
  });

  test('tocar uma música no carro toca a playlist a partir dela', () async {
    final songs = await car().children('playlist:p1');
    await car().play(songs[1].id);
    final state = container.read(playerProvider);
    expect(state.current!.track.title, 'B');
    expect(state.upNext.map((i) => i.track.title), ['C']);
    expect(state.context, 'Rock in Metal');
    expect(state.playlistId, 'p1');
  });

  test('busca por voz toca a primeira e começa a rádio', () async {
    await car().search('queen');
    final state = container.read(playerProvider);
    expect(state.current, isNotNull);
    expect(state.context, startsWith('Rádio de '));
  });

  test('fila no carro: tocar um item pula para ele', () async {
    await car().play('playlist:p1');
    final queue = car().queueOf(container.read(playerProvider));
    expect(queue.map((q) => q.title), ['B', 'C']);
    await car().skipToQueueItem(1);
    expect(container.read(playerProvider).current!.track.title, 'C');
  });
}
