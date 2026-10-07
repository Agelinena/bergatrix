import 'package:bergastream/core/widgets/app_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers.dart';

void main() {
  Widget button(String message) => Builder(
    builder: (context) => TextButton(
      onPressed: () => AppToast.show(context, message),
      child: Text('mostrar $message'),
    ),
  );

  testWidgets('aparece e some depois de 1,5 s', (tester) async {
    await tester.pumpWidget(wrap(button('Link da playlist copiado')));

    await tester.tap(find.text('mostrar Link da playlist copiado'));
    await tester.pump();
    expect(find.text('Link da playlist copiado'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1400));
    expect(find.text('Link da playlist copiado'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(find.text('Link da playlist copiado'), findsNothing);
  });

  testWidgets('um aviso novo substitui o anterior', (tester) async {
    await tester.pumpWidget(
      wrap(Column(children: [button('primeiro'), button('segundo')])),
    );

    await tester.tap(find.text('mostrar primeiro'));
    await tester.pump();
    await tester.tap(find.text('mostrar segundo'));
    await tester.pump();

    expect(find.text('primeiro'), findsNothing);
    expect(find.text('segundo'), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.text('segundo'), findsNothing);
  });
}
