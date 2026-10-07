import 'package:bergastream/core/widgets/cover.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers.dart';

void main() {
  group('Cover.hueFor', () {
    test('fica sempre entre 18 e 150', () {
      final seeds = [
        '',
        'a',
        '♫',
        'Ação',
        '🎵 emoji',
        for (var i = 0; i < 2000; i++) 'faixa-$i',
        for (var i = 0; i < 200; i++) '0b9e1c2a-$i-uuid',
      ];
      for (final seed in seeds) {
        final hue = Cover.hueFor(seed);
        expect(hue, inInclusiveRange(18, 150), reason: 'seed "$seed"');
      }
    });

    test('dá os valores do FNV-1a de referência (iguais em web e nativo)', () {
      // Calculados com aritmética exata (Python). Na web os inteiros são
      // doubles; uma multiplicação ingênua perderia precisão e mudaria a cor.
      expect(Cover.hueFor('t1'), 130);
      expect(Cover.hueFor('t2'), 62);
      expect(Cover.hueFor('Queen'), 47);
      expect(Cover.hueFor('A Night at the Opera'), 114);
    });

    test('é estável para o mesmo id', () {
      expect(Cover.hueFor('t1'), Cover.hueFor('t1'));
      expect(Cover.hueFor('t1'), isNot(Cover.hueFor('t2')));
    });

    test('o gradiente começa no matiz do id e termina em +25', () {
      final hue = Cover.hueFor('t3');
      final colors = Cover.gradientFor('t3').colors;
      expect(HSLColor.fromColor(colors.first).hue, closeTo(hue, 1));
      expect(HSLColor.fromColor(colors.last).hue, closeTo(hue + 25, 1));
    });
  });

  group('Cover.initialOf', () {
    test('usa o primeiro caractere do título', () {
      expect(Cover.initialOf('Blinding Lights'), 'B');
      expect(Cover.initialOf('  levitating'), 'l');
      expect(Cover.initialOf(' Éden'), 'É');
    });

    test('título vazio não tem inicial', () {
      expect(Cover.initialOf(''), isNull);
      expect(Cover.initialOf('   '), isNull);
    });
  });

  testWidgets('mostra a inicial quando não há imagem', (tester) async {
    await tester.pumpWidget(
      wrap(const Cover(seed: 't1', title: 'Creep', size: 46)),
    );
    expect(find.text('C'), findsOneWidget);
    final size = tester.getSize(find.byType(Cover));
    expect(size, const Size(46, 46));
  });

  testWidgets('capa de playlist sem foto mostra a nota', (tester) async {
    await tester.pumpWidget(wrap(const Cover.playlist(size: 56)));
    expect(find.byIcon(Icons.music_note), findsOneWidget);
  });

  testWidgets('título vazio mostra a nota', (tester) async {
    await tester.pumpWidget(wrap(const Cover(seed: 'x', title: '', size: 46)));
    expect(find.byIcon(Icons.music_note), findsOneWidget);
  });
}
