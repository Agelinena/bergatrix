import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:bergastream/core/theme/berga_theme.dart';
import 'package:bergastream/features/library/cover_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Foto de teste 400x200 (paisagem) em PNG.
Future<Uint8List> _photo() async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder)
    ..drawRect(const Rect.fromLTWH(0, 0, 200, 200), Paint()..color = Colors.red)
    ..drawRect(
      const Rect.fromLTWH(200, 0, 200, 200),
      Paint()..color = Colors.blue,
    );
  final image = await recorder.endRecording().toImage(400, 200);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

void main() {
  Future<EditedCover?> open(WidgetTester tester, String button) async {
    final bytes = (await tester.runAsync(_photo))!;
    EditedCover? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: BergaTheme.dark,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showCoverEditor(
                context,
                bytes,
                mimeType: 'image/png',
                filename: 'foto.png',
              );
            },
            child: const Text('abrir'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('abrir'));
    // Decodificar a foto é assíncrono de verdade.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Foto da playlist'), findsOneWidget);
    await tester.tap(find.text(button));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('"Usar inteira" devolve a foto original', (tester) async {
    final r = await open(tester, 'Usar inteira');
    expect(r, isNotNull);
    expect(r!.filename, 'foto.png');
    expect(r.mimeType, 'image/png');
  });

  testWidgets('"Recortar" devolve um quadrado', (tester) async {
    final r = await open(tester, 'Recortar');
    expect(r, isNotNull);
    expect(r!.filename, 'capa.png');
    final size = (await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(r.bytes);
      final frame = await codec.getNextFrame();
      return (frame.image.width, frame.image.height);
    }))!;
    expect(size.$1, size.$2, reason: 'quadrado');
    expect(size.$1, 200, reason: 'o lado menor da foto (sem aumentar)');
  });

  testWidgets('"Cancelar" não muda nada', (tester) async {
    expect(await open(tester, 'Cancelar'), isNull);
  });
}
