import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/berga_colors.dart';
import '../../core/widgets/widgets.dart';
import '../auth/session.dart';
import 'sync_service.dart';

/// "Sincronizar agora" e o aviso com o resultado.
Future<void> syncNow(BuildContext context, WidgetRef ref) async {
  final report = await ref.read(syncServiceProvider.notifier).syncNow();
  if (context.mounted) AppToast.show(context, report.message);
}

/// Botão de sincronizar com a nuvem (Biblioteca e barra lateral). Some sem
/// conta; gira enquanto sincroniza.
class SyncNowButton extends ConsumerWidget {
  const SyncNowButton({super.key, this.size = 22});

  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = BergaColors.of(context);
    if (!ref.watch(sessionProvider.select((s) => s.isLoggedIn))) {
      return const SizedBox.shrink();
    }
    final syncing = ref.watch(syncServiceProvider);
    return IconButton(
      onPressed: syncing ? null : () => syncNow(context, ref),
      tooltip: 'Sincronizar com a nuvem',
      icon: syncing
          ? SizedBox.square(
              dimension: size - 4,
              child: CircularProgressIndicator(strokeWidth: 2, color: c.gr),
            )
          : Icon(Icons.cloud_sync_outlined, size: size, color: c.mu),
    );
  }
}
