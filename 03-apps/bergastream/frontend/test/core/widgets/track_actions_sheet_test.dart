import 'package:bergastream/core/theme/berga_colors.dart';
import 'package:bergastream/core/widgets/track_actions_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers.dart';

void main() {
  Future<void> openSheet(WidgetTester tester, TrackActionsSheet sheet) async {
    await tester.pumpWidget(
      wrap(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => TrackActionsSheet.show(context, sheet),
            child: const Text('abrir'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
  }

  testWidgets('mostra as ações na ordem da especificação', (tester) async {
    await openSheet(
      tester,
      const TrackActionsSheet(id: 't7', title: 'Creep', artist: 'Radiohead'),
    );
    const labels = [
      'Compartilhar',
      'Adicionar à playlist',
      'Adicionar à fila',
      'Ir para o álbum',
      'Ir para o artista',
    ];
    final tops = [for (final l in labels) tester.getTopLeft(find.text(l)).dy];
    expect(tops, [...tops]..sort());
  });

  testWidgets('ação habilitada fecha a folha e executa', (tester) async {
    var queued = 0;
    await openSheet(
      tester,
      TrackActionsSheet(
        id: 't7',
        title: 'Creep',
        artist: 'Radiohead',
        onAddToQueue: () => queued++,
      ),
    );
    await tester.tap(find.text('Adicionar à fila'));
    await tester.pumpAndSettle();
    expect(queued, 1);
    expect(find.text('Adicionar à fila'), findsNothing);
  });

  testWidgets('ação sem callback fica em mu e mostra a explicação', (
    tester,
  ) async {
    await openSheet(
      tester,
      const TrackActionsSheet(
        id: 't7',
        title: 'Creep',
        artist: 'Radiohead',
        disabledMessage: 'Entre para usar esta opção.',
      ),
    );
    final style = tester.widget<Text>(find.text('Compartilhar')).style!;
    expect(style.color, BergaColors.dark.mu);

    await tester.tap(find.text('Compartilhar'));
    await tester.pump();
    expect(find.text('Entre para usar esta opção.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  });
}
