import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/router.dart';
import '../../core/network/api_error.dart';
import '../../core/widgets/widgets.dart';
import '../../data/local/database.dart';
import '../../data/models/search_result.dart';
import '../../data/repositories/local_playlists.dart';
import '../../data/repositories/playlist_repository.dart';
import '../auth/session.dart';
import '../library/library_providers.dart';

/// Ao entrar com login num aparelho com playlists locais, pergunta se envia
/// para o servidor (Seção 8.6): "Enviar" / "Manter só aqui".
class LocalPlaylistsOffer extends ConsumerWidget {
  const LocalPlaylistsOffer({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(sessionProvider.select((s) => s.isLoggedIn), (was, now) {
      if (was != true && now) _offerAfterLogin(ref);
    });
    return child;
  }
}

/// Espera a lista local ser lida e o login terminar de navegar para o
/// Início: um diálogo aberto durante a troca de rota seria descartado.
Future<void> _offerAfterLogin(WidgetRef ref) async {
  await ref.read(localPlaylistsProvider.notifier).loaded;
  if (ref.read(localPlaylistsProvider).isEmpty) return;
  await Future<void>.delayed(const Duration(milliseconds: 400));
  // Este widget fica acima do Navigator (builder do MaterialApp): o diálogo
  // usa o contexto do navigator do router.
  // Contexto abaixo do Overlay do navigator (diálogo e avisos rápidos).
  final context = ref
      .read(routerProvider)
      .routerDelegate
      .navigatorKey
      .currentState
      ?.overlay
      ?.context;
  if (context != null && context.mounted) await offerUpload(context, ref);
}

Future<void> offerUpload(BuildContext context, WidgetRef ref) async {
  await ref.read(localPlaylistsProvider.notifier).loaded;
  if (!context.mounted) return;
  final local = ref.read(localPlaylistsProvider);
  if (local.isEmpty) return;
  final choice = await showChoiceDialog(
    context,
    message: 'Enviar suas playlists locais para o servidor?',
    options: const ['Manter só aqui', 'Enviar'],
  );
  if (choice != 1) return;
  final repo = ref.read(playlistRepositoryProvider);
  final db = ref.read(localDatabaseProvider);
  var sent = 0;
  for (final p in local) {
    try {
      final created = await repo.create(p.name);
      final tracks = <SearchResult>[
        for (final id in p.trackIds)
          if (await db?.track(id) case final t?) t.asResult,
      ];
      if (tracks.isNotEmpty) await repo.addTracks(created.id, tracks);
      await ref.read(localPlaylistsProvider.notifier).delete(p.id);
      sent++;
    } on ApiException catch (e) {
      if (context.mounted) AppToast.show(context, e.message);
      break;
    }
  }
  ref.invalidate(myPlaylistsProvider);
  if (sent > 0 && context.mounted) {
    AppToast.show(
      context,
      sent == 1 ? '1 playlist enviada' : '$sent playlists enviadas',
    );
  }
}
