import 'package:bergastream/core/theme/berga_colors.dart';
import 'package:bergastream/core/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers.dart';

void main() {
  Color titleColor(WidgetTester tester) =>
      tester.widget<Text>(find.text('Blinding Lights')).style!.color!;

  testWidgets('faixa tocando tem o título em verde', (tester) async {
    await tester.pumpWidget(
      wrap(
        const TrackRow(
          id: 't1',
          title: 'Blinding Lights',
          artist: 'The Weeknd',
          playing: true,
        ),
      ),
    );
    expect(titleColor(tester), BergaColors.dark.gr);
  });

  testWidgets('faixa parada tem o título na cor do texto', (tester) async {
    await tester.pumpWidget(
      wrap(
        const TrackRow(
          id: 't1',
          title: 'Blinding Lights',
          artist: 'The Weeknd',
        ),
      ),
    );
    expect(titleColor(tester), BergaColors.dark.tx);
  });

  testWidgets('faixa baixada mostra o ícone verde', (tester) async {
    await tester.pumpWidget(
      wrap(
        const TrackRow(
          id: 't1',
          title: 'Blinding Lights',
          artist: 'The Weeknd',
          downloadState: DownloadState.baixada,
        ),
      ),
    );
    final icon = tester.widget<Icon>(find.byIcon(Icons.download_done));
    expect(icon.color, BergaColors.dark.gr);
  });

  testWidgets('faixa não baixada não mostra ícone', (tester) async {
    await tester.pumpWidget(
      wrap(
        const TrackRow(
          id: 't1',
          title: 'Blinding Lights',
          artist: 'The Weeknd',
        ),
      ),
    );
    expect(find.byIcon(Icons.download_done), findsNothing);
  });

  testWidgets('mostra quem adicionou', (tester) async {
    await tester.pumpWidget(
      wrap(
        const TrackRow(
          id: 't1',
          title: 'Blinding Lights',
          artist: 'The Weeknd',
          addedBy: 'Ana',
        ),
      ),
    );
    expect(find.text('The Weeknd · por Ana'), findsOneWidget);
  });

  testWidgets('toque na linha toca e toque no ⋮ abre as opções', (
    tester,
  ) async {
    var taps = 0;
    var more = 0;
    await tester.pumpWidget(
      wrap(
        TrackRow(
          id: 't1',
          title: 'Blinding Lights',
          artist: 'The Weeknd',
          onTap: () => taps++,
          onMore: () => more++,
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.more_vert));
    expect(more, 1);
    expect(taps, 0);

    await tester.tap(find.text('Blinding Lights'));
    expect(taps, 1);
    expect(more, 1);
  });
}
