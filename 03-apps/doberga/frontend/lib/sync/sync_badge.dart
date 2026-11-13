import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/widgets.dart';
import 'sync_controller.dart';

/// Ícone na barra do app: sincronizado, sincronizando, sem conexão (com o
/// número de alterações guardadas no aparelho) ou erro. Tocar sincroniza.
class SyncBadge extends ConsumerWidget {
  const SyncBadge({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(syncProvider);
    final (icon, tip) = switch (status.phase) {
      SyncPhase.syncing => (Icons.sync, 'Sincronizando…'),
      SyncPhase.offline => (
        Icons.cloud_off_outlined,
        status.pending > 0
            ? 'Sem conexão. ${status.pending} alteraç${status.pending == 1 ? 'ão guardada' : 'ões guardadas'} no aparelho.'
            : 'Sem conexão. Tudo funciona; sincroniza quando voltar.',
      ),
      SyncPhase.upgradeRequired => (Icons.system_update, status.error ?? 'Atualize o app'),
      SyncPhase.error => (Icons.sync_problem, status.error ?? 'Falha ao sincronizar'),
      SyncPhase.idle => status.pending > 0
          ? (Icons.cloud_upload_outlined, '${status.pending} para enviar')
          : (Icons.cloud_done_outlined, 'Sincronizado'),
    };
    final button = IconButton(
      tooltip: tip,
      icon: Icon(icon),
      onPressed: () {
        toast(context, tip);
        ref.read(syncProvider.notifier).syncNow();
      },
    );
    if (status.pending == 0 || status.phase == SyncPhase.syncing) return button;
    return Badge.count(count: status.pending, offset: const Offset(-4, 4), child: button);
  }
}

/// Faixa com as alterações que o servidor recusou.
class SyncNoticesBanner extends ConsumerWidget {
  const SyncNoticesBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notices = ref.watch(noticesProvider).value ?? const [];
    if (notices.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.errorContainer,
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final n in notices.reversed.take(5))
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(n.message,
                    style: TextStyle(color: theme.colorScheme.onErrorContainer)),
              ),
            if (notices.length > 5)
              Text('e mais ${notices.length - 5}',
                  style: TextStyle(color: theme.colorScheme.onErrorContainer)),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => ref.read(storeProvider).clearNotices(),
                child: const Text('Entendi'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
