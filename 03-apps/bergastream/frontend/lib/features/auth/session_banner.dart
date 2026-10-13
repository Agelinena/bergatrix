import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/routes.dart';
import '../../core/platform/app_platform.dart';
import '../../core/widgets/offline_banner.dart';
import '../sync/server_monitor.dart';
import 'auth_texts.dart';
import 'session.dart';

/// Aviso fino acima do conteúdo (Seção 2.3): sessão expirada ou servidor
/// indisponível. Na web a sessão expirada volta ao login.
class SessionBanner extends ConsumerWidget {
  const SessionBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    if (ref.watch(appPlatformProvider).isWeb) {
      // Web: sessão expirada volta ao login; sem músicas baixadas.
      return session.isLoggedIn && !session.serverAvailable
          ? OfflineBanner(
              message: AuthTexts.serverUnavailableWeb,
              actionLabel: 'Tentar agora',
              onAction: () => ref.read(serverMonitorProvider.notifier).check(),
            )
          : const SizedBox.shrink();
    }

    if (session.status == SessionStatus.sessaoExpirada) {
      return OfflineBanner(
        message: AuthTexts.sessionExpired,
        actionLabel: 'Entrar',
        onAction: () => context.go(AppRoutes.login),
      );
    }
    if (session.isLoggedIn && !session.serverAvailable) {
      return OfflineBanner(
        message: AuthTexts.serverUnavailable,
        actionLabel: 'Tentar agora',
        onAction: () => ref.read(serverMonitorProvider.notifier).check(),
      );
    }
    return const SizedBox.shrink();
  }
}
