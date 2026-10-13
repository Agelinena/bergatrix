import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/router.dart';
import '../../core/widgets/app_toast.dart';
import 'download_manager.dart';

/// Avisa quando um lote de cópias baixadas foi trocado por qualidade
/// melhor (antes a troca acontecia sem nenhum sinal).
class DownloadNotices extends ConsumerWidget {
  const DownloadNotices({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(downloadManagerProvider.select((s) => s.upgraded), (
      previous,
      next,
    ) {
      if (next == null || next.id == previous?.id) return;
      // Este widget fica acima do Navigator: o aviso usa o overlay do router.
      final overlay = ref
          .read(routerProvider)
          .routerDelegate
          .navigatorKey
          .currentState
          ?.overlay;
      if (overlay == null || !overlay.mounted) return;
      AppToast.show(
        overlay.context,
        next.count == 1
            ? '1 música baixada trocada por qualidade melhor'
            : '${next.count} músicas baixadas trocadas por qualidade melhor',
      );
    });
    return child;
  }
}
