import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'app.dart';
import 'providers/auth_provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();

  final container = ProviderContainer();
  await container.read(authProvider.notifier).initialize();

  // Note: loading overlay removal is handled in web/index.html via the
  // 'flutter-first-frame' event — no dart:html needed here.

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const BergaStreamApp(),
    ),
  );
}
