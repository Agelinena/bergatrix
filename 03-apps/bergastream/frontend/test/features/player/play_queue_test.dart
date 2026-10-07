import 'dart:math';

import 'package:bergastream/data/models/search_result.dart';
import 'package:bergastream/features/player/play_queue.dart';
import 'package:flutter_test/flutter_test.dart';

SearchResult t(String name) => SearchResult(
  provider: 'spotify',
  externalId: name,
  title: name,
  artist: 'A',
);

List<SearchResult> list(String names) => [
  for (final n in names.split('')) t(n),
];

String titles(Iterable<QueueItem> items) =>
    items.map((i) => i.track.title).join();

void main() {
  late PlayQueue q;
  setUp(() => q = PlayQueue(random: Random(1)));

  test('tocar uma lista: a seguir são as faixas seguintes, na ordem', () {
    q.playList(list('ABCDE'), 1);
    expect(q.current!.track.title, 'B');
    expect(titles(q.upNext), 'CDE');
  });

  test('a sua fila toca antes da fila automática', () {
    q.playList(list('ABC'), 0);
    q.add(t('X'));
    expect(q.next()!.track.title, 'X');
    expect(q.next()!.track.title, 'B');
  });

  test('duas adições à fila mantêm a ordem de chegada (FIFO)', () {
    q.playList(list('ABC'), 0);
    q.add(t('X'));
    q.add(t('Y'));
    expect(titles(q.manual), 'XY');
    expect(q.next()!.track.title, 'X');
    expect(q.next()!.track.title, 'Y');
    expect(q.next()!.track.title, 'B');
  });

  test('a mesma música pode entrar duas vezes na fila', () {
    q.playList(list('A'), 0);
    q.add(t('X'));
    q.add(t('X'));
    expect(q.manual.map((i) => i.uid).toSet(), hasLength(2));
  });

  test('aleatório embaralha só a fila automática', () {
    q.playList(list('ABCDEFGH'), 0);
    q.add(t('X'));
    q.add(t('Y'));
    q.setShuffle(true);
    expect(titles(q.manual), 'XY');
    expect(titles(q.upNext), isNot('BCDEFGH'));
    expect(q.upNext.map((i) => i.track.title).toSet(), {
      'B',
      'C',
      'D',
      'E',
      'F',
      'G',
      'H',
    });
  });

  test('desligar o aleatório volta à ordem a partir da atual', () {
    q.playList(list('ABCDE'), 0);
    q.setShuffle(true);
    q.setShuffle(false);
    expect(titles(q.upNext), 'BCDE');
  });

  test('tocar lista com aleatório ligado não repete a atual em "a seguir"', () {
    q.setShuffle(true);
    q.playList(list('ABCDE'), 2);
    expect(q.upNext.map((i) => i.track.title).toSet(), {'A', 'B', 'D', 'E'});
  });

  test('tocar uma lista nova preserva a sua fila', () {
    q.playList(list('ABC'), 0);
    q.add(t('X'));
    q.playList(list('MNO'), 0);
    expect(titles(q.manual), 'X');
    expect(q.next()!.track.title, 'X');
    expect(q.next()!.track.title, 'N');
  });

  group('fim das filas e repetir', () {
    test('desligado: para no fim', () {
      q.playList(list('AB'), 0);
      expect(q.next()!.track.title, 'B');
      expect(q.next(), isNull);
      expect(q.current!.track.title, 'B');
    });

    test('tudo: recomeça a lista de origem', () {
      q.repeat = PlayerRepeat.tudo;
      q.playList(list('AB'), 0);
      q.next();
      expect(q.next()!.track.title, 'A');
      expect(q.next()!.track.title, 'B');
    });

    test('uma faixa: ao acabar recomeça a mesma; o botão avança', () {
      q.repeat = PlayerRepeat.umaFaixa;
      q.playList(list('AB'), 0);
      expect(q.next(ended: true)!.track.title, 'A');
      expect(q.next()!.track.title, 'B');
    });

    test('o botão cicla desligado → tudo → uma faixa → desligado', () {
      expect(PlayerRepeat.desligado.next, PlayerRepeat.tudo);
      expect(PlayerRepeat.tudo.next, PlayerRepeat.umaFaixa);
      expect(PlayerRepeat.umaFaixa.next, PlayerRepeat.desligado);
    });
  });

  group('anterior', () {
    test('com mais de 3 s, recomeça a faixa', () {
      q.playList(list('ABC'), 0);
      q.next();
      expect(q.previous(const Duration(seconds: 4)), PreviousAction.reiniciar);
      expect(q.current!.track.title, 'B');
    });

    test('com até 3 s, volta à anterior e a atual volta para "a seguir"', () {
      q.playList(list('ABC'), 0);
      q.next();
      expect(q.previous(const Duration(seconds: 2)), PreviousAction.voltar);
      expect(q.current!.track.title, 'A');
      expect(titles(q.upNext), 'BC');
    });

    test('sem histórico, recomeça', () {
      q.playList(list('ABC'), 0);
      expect(q.previous(Duration.zero), PreviousAction.reiniciar);
    });
  });

  test('remover, reordenar e limpar a sua fila', () {
    q.playList(list('A'), 0);
    final x = q.add(t('X'));
    q.add(t('Y'));
    q.add(t('Z'));
    q.reorderManual(2, 0);
    expect(titles(q.manual), 'ZXY');
    q.removeManual(x.uid);
    expect(titles(q.manual), 'ZY');
    q.clearManual();
    expect(q.manual, isEmpty);
  });

  test('reordenar e remover em "a seguir"', () {
    q.playList(list('ABCD'), 0);
    // Posição final (padrão do onReorderItem): 2 = última.
    q.reorderUpNext(0, 2);
    expect(titles(q.upNext), 'CDB');
    q.removeUpNext(q.upNext.first.uid);
    expect(titles(q.upNext), 'DB');
  });
}
