import 'package:bergastream/core/platform/app_platform.dart';
import 'package:bergastream/core/storage/key_value_store.dart';
import 'package:bergastream/data/local/database.dart';
import 'package:bergastream/data/models/playlist_models.dart';
import 'package:bergastream/data/models/playlist_op.dart';
import 'package:bergastream/data/models/search_result.dart';
import 'package:bergastream/data/repositories/auth_repository.dart';
import 'package:bergastream/data/repositories/fake_auth_repository.dart';
import 'package:bergastream/data/repositories/playlist_repository.dart';
import 'package:bergastream/features/auth/session.dart';
import 'package:bergastream/features/playlists/playlist_store.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../app_harness.dart';

SearchResult song(String id) => SearchResult(
  provider: 'spotify',
  externalId: id,
  title: 'Música $id',
  artist: 'Artista',
);

void main() {
  late AppDatabase db;
  late FakePlaylistRepository repo;
  late ProviderContainer c;

  ProviderContainer create({SessionState session = loggedIn}) {
    final container = ProviderContainer(
      overrides: [
        appPlatformProvider.overrideWithValue(const AppPlatform.app()),
        keyValueStoreProvider.overrideWithValue(MemoryKeyValueStore()),
        initialSessionProvider.overrideWithValue(session),
        authRepositoryProvider.overrideWithValue(
          FakeAuthRepository(delay: Duration.zero),
        ),
        playlistRepositoryProvider.overrideWithValue(repo),
        localDatabaseProvider.overrideWithValue(db),
      ],
    );
    // Mantém vivos os providers lidos pelos testes.
    container.listen(myPlaylistsProvider, (_, _) {});
    container.listen(playlistSyncProvider, (_, _) {});
    return container;
  }

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = FakePlaylistRepository();
    c = create();
  });

  tearDown(() async {
    c.dispose();
    await db.close();
  });

  PlaylistEditor editor() => c.read(playlistEditorProvider);
  void online(bool value) =>
      c.read(sessionProvider.notifier).setServerAvailable(value);

  Future<PlaylistDetail> detail(String id) async {
    await pumpEventQueue();
    final sub = c.listen(playlistDetailProvider(id), (_, _) {});
    final value = await c.read(playlistDetailProvider(id).future);
    sub.close();
    return value;
  }

  Future<List<String>> order(String id) async => [
    for (final t in (await detail(id)).tracks) t.trackId,
  ];

  Future<FlushOutcome> flush() async {
    await pumpEventQueue();
    return c.read(playlistSyncProvider.notifier).flush();
  }

  // Direto do banco: o valor da stream no provider pode estar um passo atrás.
  Future<List<SyncNotice>> notices() async => [
    for (final r in await db.watchNotices().first) SyncNotice.fromRow(r),
  ];

  Future<List<ServerPlaylist>> lists() async {
    await pumpEventQueue();
    c.invalidate(myPlaylistsProvider);
    return c.read(myPlaylistsProvider.future);
  }

  Future<int> pending() async => (await db.playlistOpsInOrder()).length;

  /// O celular abre a playlist com servidor (guarda a cópia) e perde a
  /// conexão; edita: renomeia, tira tr1, adiciona X e põe tr3 no topo.
  Future<void> editOffline() async {
    expect((await detail('p1')).name, 'Roadtrip');
    online(false);
    final e = editor();
    await e.rename('p1', name: 'Celular', current: 'Roadtrip');
    await e.removeTrack('p1', 'tr1');
    await e.addTracks('p1', [song('x')]);
    await e.reorder(
      'p1',
      ['tr0', 'tr2', 'tr3', 'tr4'],
      ['tr3', 'tr0', 'tr2', 'tr4'],
    );
  }

  test(
    'offline: aparece na hora, fica na fila e vai na ordem ao voltar',
    () async {
      await editOffline();
      final local = await detail('p1');
      expect(local.name, 'Celular');
      expect([for (final t in local.tracks) t.trackId].take(4), [
        'tr3',
        'tr0',
        'tr2',
        'tr4',
      ]);
      expect(local.tracks.last.title, 'Música x');
      expect(repo.batches, isEmpty);
      expect(await pending(), 4);
      expect((await lists()).single.name, 'Celular');

      online(true);
      final out = await flush();
      expect(out.sent, 4);
      expect(out.notices, 0);
      expect(await pending(), 0);
      expect(repo.batches, hasLength(1));
      expect(
        [for (final o in repo.batches.single) o.type],
        [
          PlaylistOpType.rename,
          PlaylistOpType.remove,
          PlaylistOpType.add,
          PlaylistOpType.move,
        ],
      );
      expect(repo.playlists.single.name, 'Celular');
      expect(await order('p1'), ['tr3', 'tr0', 'tr2', 'tr4', 'srv-x']);
    },
  );

  test(
    'offline × web: faixas se combinam; nome em conflito vira aviso',
    () async {
      await editOffline();
      // Enquanto isso, na web: adiciona Y e renomeia.
      await repo.applyOps([
        PlaylistOp.add('p1', song('y')),
        PlaylistOp.rename('p1', name: 'Nome da web'),
      ]);
      repo.batches.clear();

      online(true);
      final out = await flush();
      expect(out.notices, 1);
      expect(await pending(), 0);
      // Nada da web se perdeu e as intenções do celular foram aplicadas.
      expect(await order('p1'), ['tr3', 'tr0', 'tr2', 'tr4', 'srv-y', 'srv-x']);
      expect(repo.playlists.single.name, 'Nome da web');

      final notice = (await notices()).single;
      expect(notice.kind, SyncNoticeKind.renameConflict);
      expect(notice.data['mine'], 'Celular');
      expect(notice.data['theirs'], 'Nome da web');

      // "Usar o meu".
      await editor().applyMine(notice);
      await flush();
      expect(repo.playlists.single.name, 'Celular');
      expect(await notices(), isEmpty);
    },
  );

  test('"Manter" o nome do servidor só some com o aviso', () async {
    await editOffline();
    await repo.rename('p1', 'Nome da web');
    online(true);
    await flush();
    final notice = (await notices()).single;
    await editor().keepServerVersion(notice);
    expect(await notices(), isEmpty);
    expect(repo.playlists.single.name, 'Nome da web');
    expect(repo.batches, hasLength(1));
  });

  test('playlist criada offline: refs viram ids do servidor', () async {
    online(false);
    final id = await editor().create('Feita no ônibus');
    expect(PlaylistOp.isRef(id), isTrue);
    await editor().addTracks(id, [song('a'), song('b')]);
    await editor().rename(id, name: 'Ônibus', current: 'Feita no ônibus');
    expect((await detail(id)).tracks, hasLength(2));
    expect((await lists()).map((p) => p.name), contains('Ônibus'));

    online(true);
    await flush();
    expect(await pending(), 0);
    final created = repo.playlists.last;
    expect(created.name, 'Ônibus');
    expect(
      [for (final t in repo.trackLists[created.id]!) t.trackId],
      ['srv-a', 'srv-b'],
    );
    // A tela aberta com o ref continua funcionando.
    final viaRef = await detail(id);
    expect(viaRef.id, created.id);
    expect(viaRef.tracks, hasLength(2));
  });

  test('alterações numa playlist apagada em outro lugar: "Recriar"', () async {
    await editOffline();
    await repo.delete('p1');
    online(true);
    final out = await flush();
    expect(out.notices, 1);
    expect(await pending(), 0);
    final notice = (await notices()).single;
    expect(notice.kind, SyncNoticeKind.gone);
    expect(notice.data['count'], 4);
    expect(notice.name, 'Celular');

    await editor().applyMine(notice);
    await flush();
    final recreated = repo.playlists.single;
    expect(recreated.name, 'Celular');
    expect(repo.trackLists[recreated.id], hasLength(5));
    expect(await notices(), isEmpty);
  });

  test(
    'apagar offline uma playlist que mudou na web: não apaga e pergunta',
    () async {
      repo.playlists[0] = const ServerPlaylist(
        id: 'p1',
        name: 'Roadtrip',
        updatedAt: 'v1',
      );
      await detail('p1');
      online(false);
      await editor().delete('p1', updatedAt: 'v1');
      expect((await lists()).where((p) => p.id == 'p1'), isEmpty);
      // Na web alguém mexeu nela.
      repo.playlists[0] = const ServerPlaylist(
        id: 'p1',
        name: 'Roadtrip',
        updatedAt: 'v2',
      );
      online(true);
      await flush();
      expect(repo.playlists, hasLength(1));
      final notice = (await notices()).single;
      expect(notice.kind, SyncNoticeKind.deleteConflict);

      await editor().applyMine(notice); // "Apagar mesmo assim"
      await flush();
      expect(repo.playlists, isEmpty);
    },
  );

  test('servidor fora ou "retry": nada se perde', () async {
    await editOffline();
    online(true);
    repo.offline = true;
    expect((await flush()).sent, 0);
    expect(await pending(), 4);

    repo
      ..offline = false
      ..opsHandler = (ops) => OpBatchResult(
        results: [
          for (final o in ops) OpResult(opId: o.opId, status: OpStatus.retry),
        ],
      );
    expect((await flush()).sent, 0);
    expect(await pending(), 4);

    repo.opsHandler = null;
    expect((await flush()).sent, 4);
    expect(await pending(), 0);
  });

  test(
    'outra conta no aparelho: cópia, fila e avisos da anterior somem',
    () async {
      c.dispose();
      c = create(
        session: const SessionState(
          status: SessionStatus.logado,
          server: testServer,
          username: 'ana',
        ),
      );
      await detail('p1');
      online(false);
      await editor().rename('p1', name: 'Da Ana', current: 'Roadtrip');
      expect(await pending(), 1);

      await c.read(sessionProvider.notifier).logout();
      await c
          .read(sessionProvider.notifier)
          .login(server: testServer, username: 'demo', password: 'demo');
      await pumpEventQueue();
      expect(await pending(), 0);
      expect(await notices(), isEmpty);
      // A lista agora é a da conta nova (do servidor), sem o nome da Ana.
      expect((await lists()).map((p) => p.name), isNot(contains('Da Ana')));
    },
  );
}
