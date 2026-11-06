import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth/login_screen.dart';
import 'auth/session.dart';
import 'core/prefs.dart';
import 'core/theme.dart';
import 'data/api.dart';
import 'home/home_screen.dart';

class BerganewsApp extends ConsumerStatefulWidget {
  const BerganewsApp({super.key});

  @override
  ConsumerState<BerganewsApp> createState() => _BerganewsAppState();
}

class _BerganewsAppState extends ConsumerState<BerganewsApp> {
  @override
  void initState() {
    super.initState();
    // Termina o login que voltou recarregando a página (web) ou reabrindo o
    // app (Android), e confere a sessão salva (um token vencido é renovado
    // pelo interceptor; sessão revogada volta ao login).
    Future.microtask(() async {
      await ref.read(sessionProvider.notifier).completePendingOidc();
      if (!ref.read(sessionProvider).isLoggedIn) return;
      try {
        await ref.read(apiProvider).me();
      } on Object {
        // Sem rede: segue com a sessão salva.
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final logged = ref.watch(sessionProvider.select((s) => s.isLoggedIn));
    final prefs = ref.watch(prefsProvider).value;
    return MaterialApp(
      title: 'Berganews',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: themeModeOf(prefs?.theme ?? 'system'),
      home: logged ? const HomeScreen() : const LoginScreen(),
    );
  }
}
