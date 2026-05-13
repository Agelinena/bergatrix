// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
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

  // Remove loading overlay before Flutter renders so it never bleeds through
  html.document.querySelector('#loading')?.remove();

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const BergaStreamApp(),
    ),
  );
}
