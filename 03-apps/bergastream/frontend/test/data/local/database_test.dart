import 'package:bergastream/core/widgets/download_state_icon.dart';
import 'package:bergastream/data/local/database.dart';
import 'package:bergastream/data/models/playlist_models.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

PlaylistTrack t(String id, {int size = 1000}) => PlaylistTrack(
  trackId: id,
  provider: 'spotify',
  externalId: 'sp-$id',
  title: 'Faixa $id',
  artist: 'Artista',
  addedAt: '2026-10-01',
  addedBy: const Person(id: 'u1', username: 'ana', name: 'Ana'),
  sizeBytes: size,
);

PlaylistDetail playlist(String id, List<String> tracks) => PlaylistDetail(
  id: id,
  name: 'Playlist $id',
  owner: const Person(id: 'u0', username: 'demo', name: 'Demo'),
  members: const [
    PlaylistMember(
      user: Person(id: 'u1', username: 'ana', name: 'Ana'),
      role: 'editor',
    ),
  ],
  tracks: [for (final x in tracks) t(x)],
);

void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<void> markDone(String id) => db.updateTrack(
    id,
    const LocalTracksCompanion(downloadState: Value(DownloadState.baixada)),
  );

  test(
    'guardar a playlist põe as faixas na fila, com ordem e quem adicionou',
    () async {
      await db.savePlaylist(playlist('p1', ['a', 'b', 'c']));
      final rows = await db.watchPlaylistTracks('p1').first;
      expect([for (final r in rows) r.$1.id], ['a', 'b', 'c']);
      expect(rows.first.$2.addedBy, 'Ana');
      expect(
        rows.every((r) => r.$1.downloadState == DownloadState.naFila),
        isTrue,
      );
      expect((await db.queuedTracks()).map((x) => x.id), ['a', 'b', 'c']);
      final collaborators = await db.watchCollaborators('p1').first;
      expect(
        collaborators.map((c) => c.userName),
        containsAll(['Demo', 'Ana']),
      );
    },
  );

  test(
    'remover o download de uma playlist não apaga faixa usada em outra',
    () async {
      await db.savePlaylist(playlist('p1', ['a', 'b']));
      await db.savePlaylist(playlist('p2', ['b', 'c']));
      final orphans = await db.removePlaylist('p1');
      expect(orphans.map((x) => x.id), ['a']);
      expect(await db.track('b'), isNotNull);
      expect(await db.track('a'), isNull);
      final last = await db.removePlaylist('p2');
      expect(last.map((x) => x.id).toSet(), {'b', 'c'});
    },
  );

  test('faixa já baixada por outra playlist é reaproveitada', () async {
    await db.savePlaylist(playlist('p1', ['a']));
    await markDone('a');
    await db.savePlaylist(playlist('p2', ['a', 'z']));
    expect((await db.track('a'))!.downloadState, DownloadState.baixada);
    expect((await db.queuedTracks()).map((x) => x.id), ['z']);
  });

  test('estados da playlist: baixando → parcial (falha) → baixada', () async {
    await db.savePlaylist(playlist('p1', ['a', 'b']));
    var p = await db.watchProgress('p1').first;
    expect((p.state, p.done, p.total), (PlaylistDownloadState.baixando, 0, 2));
    await markDone('a');
    await db.updateTrack(
      'b',
      const LocalTracksCompanion(downloadState: Value(DownloadState.falhou)),
    );
    p = await db.watchProgress('p1').first;
    expect(
      (p.state, p.done, p.failed, p.remaining),
      (PlaylistDownloadState.parcial, 1, 1, 1),
    );
    // Baixar de novo devolve a falhada para a fila.
    await db.savePlaylist(playlist('p1', ['a', 'b']));
    expect((await db.track('b'))!.downloadState, DownloadState.naFila);
    await markDone('b');
    p = await db.watchProgress('p1').first;
    expect((p.state, p.bytes), (PlaylistDownloadState.baixada, 2000));
  });

  test('pausar tira a playlist da fila', () async {
    await db.savePlaylist(playlist('p1', ['a']));
    await db.setPaused('p1', true);
    expect(await db.queuedTracks(), isEmpty);
    expect(
      (await db.watchProgress('p1').first).state,
      PlaylistDownloadState.parcial,
    );
  });

  test('faixa removida da playlist no servidor sai na atualização', () async {
    await db.savePlaylist(playlist('p1', ['a', 'b']));
    final gone = await db.savePlaylist(playlist('p1', ['b']));
    expect(gone, ['a']);
    expect((await db.releaseTracks(gone)).map((x) => x.id), ['a']);
  });

  test('busca local só nas baixadas; tocar local primeiro', () async {
    await db.savePlaylist(playlist('p1', ['a', 'b']));
    await markDone('a');
    expect((await db.searchDownloaded('faixa')).map((x) => x.id), ['a']);
    final r = (await db.track('a'))!.asResult;
    expect((await db.downloadedFor(r))?.id, 'a');
    expect(await db.downloadedFor((await db.track('b'))!.asResult), isNull);
  });

  test('reproduções pendentes em ordem e estado chave/valor', () async {
    await db.addPendingPlay('{"t":1}', DateTime(2026));
    await db.addPendingPlay('{"t":2}', DateTime(2026));
    final pending = await db.pendingPlaysInOrder();
    expect(pending.map((p) => p.trackJson), ['{"t":1}', '{"t":2}']);
    await db.deletePendingPlays([pending.first.id]);
    expect(await db.pendingPlaysInOrder(), hasLength(1));
    await db.setStateValue('wifi_only', 'false');
    expect(await db.stateValue('wifi_only'), 'false');
  });
}
