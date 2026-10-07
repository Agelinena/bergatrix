import 'dart:async';

import 'package:flutter/services.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';

/// Carrega as fontes reais para que os golden tests mostrem o texto e os
/// ícones como no app (sem isso o Flutter usa uma fonte de blocos).
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Cada teste abre o seu banco em memória.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  final bricolage = FontLoader('BricolageGrotesque');
  for (final weight in ['Regular', 'SemiBold', 'ExtraBold']) {
    bricolage.addFont(
      rootBundle.load('assets/fonts/BricolageGrotesque-$weight.ttf'),
    );
  }
  await bricolage.load();

  final icons = FontLoader('MaterialIcons')
    ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
  await icons.load();

  await testMain();
}
