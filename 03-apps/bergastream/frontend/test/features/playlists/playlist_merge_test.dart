import 'dart:convert';
import 'dart:math';

import 'package:bergastream/data/models/playlist_models.dart';
import 'package:bergastream/data/models/playlist_op.dart';
import 'package:bergastream/data/models/search_result.dart';
import 'package:bergastream/features/playlists/playlist_merge.dart';
import 'package:flutter_test/flutter_test.dart';

PlaylistTrack track(String id) => PlaylistTrack(
  trackId: id,
  provider: 'spotify',
  externalId: 'ext-$id',
  title: 'Faixa $id',
  artist: 'Artista',
  addedAt: '2026-10-01T00:00:00Z',
);

SearchResult result(String id) => SearchResult(
  provider: 'spotify',
  externalId: 'ext-$id',
  title: 'Faixa $id',
  artist: 'Artista',
);

List<String> apply(
  List<String> order,
  List<({String track, String? after, String? before})> moves,
) {
  var current = order;
  for (final m in moves) {
    current = moveInOrder(current, m.track, after: m.after, before: m.before);
  }
  return current;
}

void main() {
  group('moveInOrder (mesma regra do servidor)', () {
    const order = ['a', 'b', 'c', 'd'];

    test('depois da âncora; nulo = topo', () {
      expect(moveInOrder(order, 'd', after: 'a'), ['a', 'd', 'b', 'c']);
      expect(moveInOrder(order, 'c'), ['c', 'a', 'b', 'd']);
    });

    test('âncora sumiu: usa a de reserva; as duas sumiram: fica', () {
      expect(moveInOrder(order, 'a', after: 'x', before: 'd'), [
        'b',
        'c',
        'a',
        'd',
      ]);
      expect(moveInOrder(order, 'b', after: 'x', before: 'y'), order);
    });

    test('faixa que não está na lista: nada muda', () {
      expect(moveInOrder(order, 'z', after: 'a'), order);
    });
  });

  group('movesFor', () {
    test('arrastar uma faixa vira um único "mover"', () {
      final moves = movesFor(
        ['a', 'b', 'c', 'd', 'e'],
        ['a', 'e', 'b', 'c', 'd'],
      );
      expect(moves, hasLength(1));
      expect(moves.single, (track: 'e', after: 'a', before: 'b'));
    });

    test('mesma ordem: nada a enviar', () {
      expect(movesFor(['a', 'b'], ['a', 'b']), isEmpty);
    });

    test('para o topo usa after nulo', () {
      expect(movesFor(['a', 'b', 'c'], ['c', 'a', 'b']).single, (
        track: 'c',
        after: null,
        before: 'a',
      ));
    });

    test('qualquer permutação: os movimentos levam à ordem final', () {
      final random = Random(7);
      for (var round = 0; round < 300; round++) {
        final n = 1 + random.nextInt(25);
        final from = [for (var i = 0; i < n; i++) 't$i'];
        final to = [...from]..shuffle(random);
        final moves = movesFor(from, to);
        expect(apply(from, moves), to, reason: '$from → $to');
        // Só quem saiu do lugar se move (fica a maior sequência em ordem).
        expect(moves.length, lessThan(n));
      }
    });

    test('vale mesmo se o servidor ganhou faixas nesse meio-tempo', () {
      final moves = movesFor(['a', 'b', 'c'], ['c', 'a', 'b']);
      // No servidor alguém adicionou "x" no fim e "y" no meio.
      expect(apply(['a', 'y', 'b', 'c', 'x'], moves), [
        'c',
        'a',
        'y',
        'b',
        'x',
      ]);
    });
  });

  group('applyOpsToDetail', () {
    final base = PlaylistDetail(
      id: 'p1',
      name: 'Roadtrip',
      tracks: [track('a'), track('b'), track('c')],
    );
    const me = Person(id: '', username: 'demo', name: 'demo');

    test('renomear, adicionar, remover e mover', () {
      final add = PlaylistOp.add('p1', result('x'));
      final p = applyOpsToDetail(base, [
        PlaylistOp.rename('p1', name: 'Celular', base: 'Roadtrip'),
        add,
        PlaylistOp.remove('p1', 'b'),
        PlaylistOp.move('p1', 'c'),
        PlaylistOp.rename('outra', name: 'Ignorada'),
      ], me: me)!;
      expect(p.name, 'Celular');
      expect([for (final t in p.tracks) t.trackId], ['c', 'a', add.ref]);
      expect([for (final t in p.tracks) t.position], [1, 2, 3]);
      expect(p.tracks.last.addedBy?.username, 'demo');
    });

    test('adicionar faixa que já está: não duplica', () {
      final p = applyOpsToDetail(base, [PlaylistOp.add('p1', result('a'))])!;
      expect(p.tracks, hasLength(3));
    });

    test('apagada: nulo', () {
      expect(applyOpsToDetail(base, [PlaylistOp.delete('p1')]), isNull);
    });
  });

  test('applyOpsToList: criar, renomear, contar e apagar', () {
    const base = [
      ServerPlaylist(id: 'p1', name: 'Roadtrip', trackCount: 2),
      ServerPlaylist(id: 'p2', name: 'Velha'),
    ];
    final create = PlaylistOp.create(ref: PlaylistOp.newRef(), name: 'Nova');
    final list = applyOpsToList(base, [
      create,
      PlaylistOp.rename('p1', name: 'Viagem'),
      PlaylistOp.add('p1', result('x')),
      PlaylistOp.remove('p1', 'a'),
      PlaylistOp.remove('p1', 'b'),
      PlaylistOp.delete('p2'),
    ]);
    expect([for (final p in list) p.name], ['Nova', 'Viagem']);
    expect(list.first.id, create.ref);
    expect(list.last.trackCount, 1);
  });

  group('PlaylistOp', () {
    test('JSON de ida e volta (fila no aparelho)', () {
      for (final op in [
        PlaylistOp.create(ref: 'tmp:1', name: 'Nova'),
        PlaylistOp.rename('p1', name: 'B', base: 'A'),
        PlaylistOp.add('p1', result('x')),
        PlaylistOp.remove('p1', 't1'),
        PlaylistOp.move('p1', 't1', after: null, before: 't2'),
        PlaylistOp.delete('p1', baseUpdatedAt: '2026-10-07T10:00:00Z'),
      ]) {
        final again = PlaylistOp.fromJson(
          jsonDecode(jsonEncode(op)) as Map<String, dynamic>,
        );
        expect(jsonEncode(again), jsonEncode(op));
      }
    });

    test('mover para o topo manda after nulo explícito', () {
      final json = PlaylistOp.move('p1', 't1').toJson();
      expect(json.containsKey('after'), isTrue);
      expect(json['after'], isNull);
    });

    test('remap troca refs pelos ids do servidor', () {
      final op = PlaylistOp.move(
        'tmp:p',
        'tmp:t',
        after: 'tmp:a',
        before: 'b',
      ).remap({'tmp:p': 'P', 'tmp:t': 'T', 'tmp:a': 'A'});
      expect(
        (op.playlist, op.trackId, op.after, op.before),
        ('P', 'T', 'A', 'b'),
      );
    });

    test('ids são UUID v4 distintos', () {
      final ids = {for (var i = 0; i < 1000; i++) PlaylistOp.newOpId()};
      expect(ids, hasLength(1000));
      expect(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ).hasMatch(ids.first),
        isTrue,
      );
    });
  });
}
