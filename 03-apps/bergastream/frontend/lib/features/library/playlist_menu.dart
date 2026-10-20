import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/routes.dart';
import '../../core/network/api_error.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/search_result.dart';
import '../auth/session.dart';
import '../player/player_controller.dart';
import '../player/track_menu.dart';
import '../playlists/playlist_store.dart';

/// Menu de uma playlist da Biblioteca/barra lateral (botão direito): tocar,
/// aleatório, pôr tudo na fila, compartilhar e abrir.
Future<void> showPlaylistMenu(
  BuildContext context,
  WidgetRef ref, {
  required String id,
  required String name,
  ImageProvider? cover,
}) {
  final router = GoRouter.of(context);

  Future<List<SearchResult>?> tracks() async {
    // Mantém o detalhe vivo enquanto carrega (provider autoDispose).
    final sub = ref.listenManual(playlistDetailProvider(id), (_, _) {});
    try {
      final detail = await ref.read(playlistDetailProvider(id).future);
      return [for (final t in detail.tracks) t.asResult];
    } on ApiException catch (e) {
      if (context.mounted) AppToast.show(context, e.message);
      return null;
    } finally {
      sub.close();
    }
  }

  Future<void> play({required bool shuffle}) async {
    final list = await tracks();
    if (list == null || list.isEmpty) return;
    await ref
        .read(playerProvider.notifier)
        .playList(
          list,
          shuffle ? Random().nextInt(list.length) : 0,
          context: name,
          playlistId: id,
          shuffle: shuffle,
        );
  }

  return TrackActionsSheet.show(
    context,
    TrackActionsSheet(
      id: id,
      title: name,
      artist: 'Playlist',
      cover: cover,
      extraActions: [
        ('Tocar', () => play(shuffle: false)),
        ('Tocar no aleatório', () => play(shuffle: true)),
        (
          'Adicionar à fila',
          () async {
            final list = await tracks();
            if (list == null || list.isEmpty) return;
            await ref.read(playerProvider.notifier).addAllToQueue(list);
            if (context.mounted) {
              AppToast.show(context, '${list.length} músicas na fila');
            }
          },
        ),
        (
          'Compartilhar',
          () => shareText(
            context,
            ref,
            '${ref.read(sessionProvider).server ?? ''}/#${AppRoutes.playlist(id)}',
            copiedMessage: 'Link da playlist copiado',
          ),
        ),
        ('Abrir', () => router.go(AppRoutes.playlist(id))),
      ],
    ),
    hideTrackActions: true,
  );
}
