import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/platform/app_platform.dart';
import '../core/theme/berga_theme.dart';
import '../features/auth/session.dart';
import '../features/devices/device_controller.dart';
import '../features/downloads/download_manager.dart';
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
  @override
  void initState() {
    super.initState();
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

  @override
  Widget build(BuildContext context) {
    // "Tocar em…": mantém este aparelho conectado aos outros da conta (um
    // "read" só não refaz a conexão ao entrar ou sair da conta).
    ref.listen(devicesProvider, (_, _) {});
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
              child: LocalPlaylistsOffer(child: child!),
            ),
          ),
        ),
      ),
    );
  }
}
