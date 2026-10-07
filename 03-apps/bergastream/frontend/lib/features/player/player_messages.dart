import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/widgets/app_toast.dart';
import 'player_controller.dart';

/// Mostra como aviso rápido as mensagens do player (erro ao tocar, modo de
/// repetição).
class PlayerMessages extends ConsumerWidget {
  const PlayerMessages({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(playerProvider.select((s) => s.message), (previous, next) {
      if (next != null && next.id != previous?.id) {
        AppToast.show(context, next.text);
      }
    });
    return child;
  }
}
