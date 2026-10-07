import 'package:bergastream/app/dev/gallery_screen.dart';
import 'package:bergastream/core/theme/berga_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Golden tests da galeria nos dois temas. Para regenerar as imagens:
/// `flutter test --update-goldens test/app/gallery_golden_test.dart`
/// (sempre na imagem Docker do Flutter, para a renderização ser igual).
void main() {
  for (final (name, theme) in [
    ('escuro', BergaTheme.dark),
    ('claro', BergaTheme.light),
  ]) {
    testWidgets('galeria no tema $name', (tester) async {
      tester.view.physicalSize = const Size(430, 2300);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          home: const GalleryScreen(),
        ),
      );
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(GalleryScreen),
        matchesGoldenFile('goldens/galeria_$name.png'),
      );
    });
  }
}
