import 'package:bergastream/core/theme/berga_colors.dart';
import 'package:bergastream/core/widgets/buttons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers.dart';

void main() {
  Color background(WidgetTester tester) {
    final container = tester.widget<Container>(
      find.descendant(
        of: find.byType(AppChip),
        matching: find.byType(Container),
      ),
    );
    return (container.decoration! as ShapeDecoration).color!;
  }

  testWidgets('chip ativo: fundo laranja, texto on, peso 600', (tester) async {
    await tester.pumpWidget(
      wrap(const AppChip(label: 'Spotify', active: true)),
    );
    final style = tester.widget<Text>(find.text('Spotify')).style!;
    expect(background(tester), BergaColors.dark.ac);
    expect(style.color, BergaColors.dark.on);
    expect(style.fontWeight, FontWeight.w600);
  });

  testWidgets('chip inativo: fundo card, texto tx, peso 400', (tester) async {
    await tester.pumpWidget(wrap(const AppChip(label: 'YT Music')));
    final style = tester.widget<Text>(find.text('YT Music')).style!;
    expect(background(tester), BergaColors.dark.card);
    expect(style.color, BergaColors.dark.tx);
    expect(style.fontWeight, FontWeight.w400);
  });

  testWidgets('toque chama onTap', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      wrap(AppChip(label: 'Aleatório', onTap: () => taps++)),
    );
    await tester.tap(find.text('Aleatório'));
    expect(taps, 1);
  });
}
