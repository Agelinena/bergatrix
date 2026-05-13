import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/theme/app_theme.dart';
import 'core/router/app_router.dart';

class BergaStreamApp extends ConsumerWidget {
  const BergaStreamApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);

    return MaterialApp.router(
      title: 'BergaStream',
      debugShowCheckedModeBanner: false,
      theme: buildDarkTheme(),
      routerConfig: router,
    );
  }
}
