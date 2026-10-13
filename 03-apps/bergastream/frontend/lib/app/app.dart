import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/platform/app_platform.dart';
import '../core/theme/berga_theme.dart';
import '../features/auth/session.dart';
import '../features/devices/device_controller.dart';
import '../features/downloads/download_manager.dart';
import '../features/downloads/download_notices.dart';
import '../features/sync/local_playlists_offer.dart';
import '../features/sync/server_monitor.dart';
import '../features/sync/sync_service.dart';
import '../features/playlists/sync_notices.dart';
import '../features/session/session_sheet.dart';
import '../features/settings/preferences.dart';
import '../features/update/update_prompt.dart';
import 'app_frame.dart';
import 'router.dart';

class BergastreamApp extends ConsumerStatefulWidget {
  const BergastreamApp({super.key});

  @override
  ConsumerState<BergastreamApp> createState() => _BergastreamAppState();
}

class _BergastreamAppState extends ConsumerState<BergastreamApp> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // De volta ao app (o Android congela o processo em segundo plano e os
    // timers param): confere o servidor na hora, retoma downloads e as
    // conexões em tempo real, sem precisar fechar e abrir.
    _lifecycle = AppLifecycleListener(onResume: _onResume);
    // Confere a sessão salva no servidor (token vencido, servidor fora do ar).
    Future.microtask(() => ref.read(sessionProvider.notifier).validate());
    // Retoma downloads que ficaram pela metade (Seção 8.5).
    Future.microtask(() => ref.read(downloadManagerProvider.notifier).start());
    // Detecção do servidor e sincronização ao reconectar (Passo 11).
    Future.microtask(() {
      ref.read(serverMonitorProvider.notifier).start();
      ref.read(syncServiceProvider.notifier).run();
    });
  }

  void _onResume() {
    final session = ref.read(sessionProvider);
    if (!session.isLoggedIn) return;
    unawaited(ref.read(serverMonitorProvider.notifier).check());
    unawaited(ref.read(downloadManagerProvider.notifier).start());
    ref.read(devicesProvider.notifier).reconnectNow();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Serviços que precisam ficar vivos: um "read" só não basta (o Riverpod
    // pausa provider sem ouvinte, e aí o monitor não tentava reconectar e o
    // app só voltava fechando e abrindo). "Tocar em…": este aparelho
    // conectado aos outros da conta.
    ref
      ..listen(serverMonitorProvider, (_, _) {})
      ..listen(syncServiceProvider, (_, _) {})
      ..listen(downloadManagerProvider, (_, _) {})
      ..listen(devicesProvider, (_, _) {});
    final platform = ref.watch(appPlatformProvider);
    return MaterialApp.router(
      title: 'Bergastream',
      debugShowCheckedModeBanner: false,
      theme: BergaTheme.light,
      darkTheme: BergaTheme.dark,
      themeMode: ref.watch(preferencesProvider.select((p) => p.theme.mode)),
      routerConfig: ref.watch(routerProvider),
      builder: (context, child) => AppFrame(
        platform: platform,
        child: UpdateWatcher(
          child: SessionInviteWatcher(
            child: SyncNoticesListener(
              child: DownloadNotices(child: LocalPlaylistsOffer(child: child!)),
            ),
          ),
        ),
      ),
    );
  }
}
