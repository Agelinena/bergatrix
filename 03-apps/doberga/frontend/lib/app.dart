import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth/login_screen.dart';
import 'auth/session.dart';
import 'core/theme.dart';
import 'data/api.dart';
import 'settings/prefs.dart';
import 'shell.dart';
import 'sync/sync_controller.dart';

class DobergaApp extends ConsumerStatefulWidget {
  const DobergaApp({super.key});

  @override
  ConsumerState<DobergaApp> createState() => _DobergaAppState();
}

class _DobergaAppState extends ConsumerState<DobergaApp> {
  @override
  void initState() {
    super.initState();
    // Termina o login que voltou recarregando a página (web) ou reabrindo o
    // app (Android), e confere a sessão salva. Sem rede, segue com a sessão
    // salva: o app funciona offline.
    Future.microtask(() async {
      await ref.read(sessionProvider.notifier).completePendingOidc();
      if (!ref.read(sessionProvider).isLoggedIn) return;
      try {
        await ref.read(apiProvider).me();
      } on Object {
        // Sem rede.
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final logged = ref.watch(sessionProvider.select((s) => s.isLoggedIn));
    // O tema vem das preferências, que só existem com o banco local aberto.
    final storeReady = logged && ref.watch(localStoreProvider).hasValue;
    final theme = storeReady ? ref.watch(prefsProvider).value?.theme : null;
    return MaterialApp(
      title: 'Doberga',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: themeModeOf(theme ?? 'system'),
      home: logged ? const StoreGate() : const LoginScreen(),
    );
  }
}
