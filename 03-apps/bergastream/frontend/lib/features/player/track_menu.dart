import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/platform/app_platform.dart';
import '../../core/utils/links.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/search_result.dart';
import '../auth/session.dart';
import '../library/add_to_playlist.dart';
import 'player_controller.dart';
import 'player_texts.dart';

/// Arrastar a linha / "Adicionar à fila": entra na sua fila com o aviso.
void queueTrack(BuildContext context, WidgetRef ref, SearchResult track) {
  ref.read(playerProvider.notifier).addToQueue(track);
  AppToast.show(context, 'Na fila: toca depois da atual');
}

/// Folha de ações (⋮) completa de uma faixa do servidor (Seção 5.4).
/// "Ir para o álbum/artista" precisam dos ids, que o backend só entrega
/// nas telas de artista e álbum (Passo 7): sem eles ficam desabilitados.
Future<void> showTrackMenu(
  BuildContext context,
  WidgetRef ref,
  SearchResult track, {
  VoidCallback? onGoToAlbum,
  VoidCallback? onGoToArtist,
  List<(String, VoidCallback)> extraActions = const [],
}) {
  final server = ref.read(sessionProvider).canUseServer;
  return TrackActionsSheet.show(
    context,
    TrackActionsSheet(
      id: track.id,
      title: track.title,
      artist: track.artist,
      cover: coverImage(track),
      onShare: () => shareTrack(context, ref, track),
      onAddToPlaylist: server
          ? () => addToPlaylist(context, ref, tracks: [track])
          : null,
      onAddToQueue: () => queueTrack(context, ref, track),
      onGoToAlbum: onGoToAlbum,
      onGoToArtist: onGoToArtist,
      extraActions: extraActions,
      disabledMessage: server
          ? 'Indisponível para músicas desta origem'
          : 'Entre para usar esta opção',
    ),
  );
}

/// Compartilhar (Seção 6.3): pergunta entre o link do serviço de origem
/// ("Link do Spotify") e o link do app. No app abre o compartilhamento do
/// sistema; na web copia o link.
Future<void> shareTrack(
  BuildContext context,
  WidgetRef ref,
  SearchResult track,
) async {
  final external = externalLinkFor(track);
  if (external == null) return;
  final server = ref.read(sessionProvider).server ?? '';
  final choice = await showChoiceDialog(
    context,
    message: 'Compartilhar ${track.title}',
    options: [external.label, 'Link do app'],
  );
  if (choice == null || !context.mounted) return;
  final url = choice == 0 ? external.url : appLinkFor(server, external.url);
  await shareText(context, ref, url, copiedMessage: 'Link copiado');
}

/// Compartilha [text]: folha do sistema no app, área de transferência na web.
Future<void> shareText(
  BuildContext context,
  WidgetRef ref,
  String text, {
  required String copiedMessage,
}) async {
  final platform = ref.read(appPlatformProvider);
  if (platform.isApp && !platform.simulated) {
    await SharePlus.instance.share(ShareParams(text: text));
    return;
  }
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) AppToast.show(context, copiedMessage);
}
