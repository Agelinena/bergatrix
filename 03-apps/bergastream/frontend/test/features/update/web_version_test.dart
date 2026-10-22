import 'package:bergastream/core/theme/berga_theme.dart';
import 'package:bergastream/features/update/web_version_watcher.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Sai da aba e volta (passando pelos estados intermediários).
void backToTab(WidgetTester tester) {
  for (final state in const [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
}

void main() {
  testWidgets('web: versão nova publicada oferece "Recarregar"', (
    tester,
  ) async {
    var published = '0.4.0+400';
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          webVersionFetcherProvider.overrideWithValue(() async => published),
        ],
        child: MaterialApp(
          theme: BergaTheme.dark,
          home: const WebVersionWatcher(child: Scaffold(body: Text('app'))),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Nova versão do Bergastream'), findsNothing);

    // Mesma versão ao voltar para a aba: nada.
    backToTab(tester);
    await tester.pump();
    expect(find.text('Nova versão do Bergastream'), findsNothing);

    published = '0.4.1+401';
    backToTab(tester);
    await tester.pump();
    expect(find.text('Nova versão do Bergastream'), findsOneWidget);
    expect(find.text('Recarregar'), findsOneWidget);

    await tester.tap(find.byTooltip('Depois'));
    await tester.pump();
    expect(find.text('Nova versão do Bergastream'), findsNothing);
  });
}
