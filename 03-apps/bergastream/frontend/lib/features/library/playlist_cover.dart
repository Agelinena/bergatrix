import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/app_layout.dart';
import '../../core/platform/app_platform.dart';
import '../../core/theme/berga_sizes.dart';
import '../../core/widgets/widgets.dart';
import '../../data/repositories/local_playlists.dart';
import '../auth/session.dart';
import '../downloads/download_manager.dart';
import '../downloads/file_fetcher.dart';
import 'library_providers.dart';

/// Baixa as fotos das playlists (direto, sem notificação de download).
final coverFetcherProvider = Provider<FileFetcher>((ref) => DioFileFetcher());

/// Foto da playlist guardada no aparelho (apps). Aparece sem servidor e não
/// é baixada de novo a cada mudança (a URL do servidor muda com `?v=` sempre
/// que a playlist muda; o arquivo só quando a foto muda). Nulo: sem cópia.
final playlistCoverFileProvider =
    FutureProvider.family<String?, ({String id, String url})>((ref, key) async {
      final platform = ref.watch(appPlatformProvider);
      if (platform.isWeb || platform.simulated) return null;
      final dir = (await ref.read(downloadPathsProvider)()).covers;
      final version = Uri.parse(key.url).queryParameters['v'] ?? '0';
      final path = '$dir/playlist-${key.id}-$version.img';
      if (File(path).existsSync()) return path;
      final older = _copiesOf(dir, key.id);
      final session = ref.read(sessionProvider);
      if (session.canUseServer && session.server != null) {
        final partial = '$path.part';
        try {
          final url = key.url.startsWith('http')
              ? key.url
              : '${session.server}${key.url}';
          await ref.read(coverFetcherProvider).fetch(Uri.parse(url), partial);
          await File(partial).rename(path);
          for (final f in older) {
            f.deleteSync();
          }
          return path;
        } on Object catch (e) {
          debugPrint('Foto da playlist ${key.id} não guardada: $e');
          try {
            File(partial).deleteSync();
          } on Object {
            // não chegou a criar
          }
        }
      }
      return older.firstOrNull?.path;
    });

List<File> _copiesOf(String dir, String id) {
  try {
    return [
      for (final f in Directory(dir).listSync())
        if (f is File &&
            f.uri.pathSegments.last.startsWith('playlist-$id-') &&
            f.path.endsWith('.img'))
          f,
    ];
  } on FileSystemException {
    return const [];
  }
}

/// Foto da playlist do servidor: a cópia do aparelho se houver; senão (web,
/// ainda baixando) a do servidor.
ImageProvider? playlistImage(WidgetRef ref, String id, String? coverUrl) {
  if (coverUrl == null) return null;
  final local = ref
      .watch(playlistCoverFileProvider((id: id, url: coverUrl)))
      .value;
  if (local != null) return FileImage(File(local));
  return serverImage(ref, coverUrl);
}

/// Foto de uma playlist "Só neste aparelho".
ImageProvider? localPlaylistImage(LocalPlaylist p) =>
    p.coverPath == null ? null : FileImage(File(p.coverPath!));

/// [Cover.playlist] com a foto de [playlistImage]; para usar dentro de
/// builders (LayoutBuilder, FutureBuilder), onde a tela não pode observar.
class ServerPlaylistCover extends ConsumerWidget {
  const ServerPlaylistCover({
    super.key,
    required this.id,
    required this.coverUrl,
    required this.size,
    this.initialSize,
  });

  final String id;
  final String? coverUrl;
  final double size;
  final double? initialSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Cover.playlist(
    size: size,
    initialSize: initialSize,
    image: playlistImage(ref, id, coverUrl),
  );
}

/// Foto no topo da tela da playlist, sempre inteira (sem cortar).
/// No celular ocupa a largura toda, na proporção da foto. No computador e
/// na web é um bloco de até [desktopBox] px com a foto inteira dentro.
/// Sem foto: o quadrado com o gradiente.
class PlaylistHeaderCover extends ConsumerWidget {
  const PlaylistHeaderCover({
    super.key,
    required this.id,
    required this.coverUrl,
    required this.maxWidth,
    this.image,
  });

  final String id;
  final String? coverUrl;
  final double maxWidth;

  /// Foto já resolvida (playlists "Só neste aparelho"); senão a do servidor.
  final ImageProvider? image;

  static const desktopBox = 260.0;

  /// No celular, foto muito alta (retrato) para aqui: o resto da tela é a lista.
  static const maxPortrait = 1.25;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final desktop = AppLayout.isDesktop(context);
    final img = image ?? playlistImage(ref, id, coverUrl);
    final placeholderSize = desktop
        ? desktopBox
        : maxWidth.clamp(0, BergaSizes.playlistCoverMaxHeight).toDouble();
    final placeholder = Cover.playlist(size: placeholderSize, initialSize: 60);
    if (img == null) {
      return Align(alignment: Alignment.centerLeft, child: placeholder);
    }
    final box = desktop
        ? const BoxConstraints(maxWidth: desktopBox, maxHeight: desktopBox)
        : BoxConstraints(maxWidth: maxWidth, maxHeight: maxWidth * maxPortrait);
    return Align(
      alignment: desktop ? Alignment.centerLeft : Alignment.center,
      child: ConstrainedBox(
        constraints: box,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(
            desktop ? BergaSizes.coverRadius : BergaSizes.cardRadius,
          ),
          child: Image(
            image: img,
            // Sem largura/altura fixas: o tamanho segue a proporção da foto
            // dentro do limite (inteira, sem corte).
            width: desktop ? null : maxWidth,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            frameBuilder: (context, child, frame, sync) =>
                frame == null && !sync ? placeholder : child,
            errorBuilder: (context, error, stack) => placeholder,
          ),
        ),
      ),
    );
  }
}
