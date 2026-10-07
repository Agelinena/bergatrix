import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_error.dart';
import '../../core/platform/app_layout.dart';
import '../../core/theme/berga_colors.dart';
import '../../core/theme/berga_sizes.dart';
import '../../core/theme/berga_text.dart';
import '../../core/widgets/widgets.dart';
import '../library/add_to_playlist.dart';
import '../player/player_controller.dart';
import '../player/player_texts.dart';
import '../player/track_menu.dart';
import 'search_providers.dart';
import '../../core/utils/format.dart';

/// Playlist ou álbum de um link colado (Seção 6.7, "Playlist importada"):
/// mesma cara do detalhe de playlist, com "Adicionar músicas à playlist" no
/// topo.
class ImportedLinkScreen extends ConsumerWidget {
  const ImportedLinkScreen({super.key, required this.url});

  final String url;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = BergaColors.of(context);
    final mu = BergaText.secondary.copyWith(color: c.mu);
    final resolved = ref.watch(resolvedLinkProvider(url));
    final playingId = ref.watch(
      playerProvider.select((s) => s.current?.track.id),
    );

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: AppLayout.screenPadding(context),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: GestureDetector(
                onTap: () => context.canPop() ? context.pop() : null,
                child: Text('‹ Buscar', style: mu),
              ),
            ),
            ...resolved.when(
              loading: () => [
                Padding(
                  padding: const EdgeInsets.only(top: 20),
                  child: Text('Abrindo link…', style: mu),
                ),
              ],
              error: (e, _) => [
                Padding(
                  padding: const EdgeInsets.only(top: 20),
                  child: Text(
                    e is ApiException
                        ? e.message
                        : 'Não foi possível abrir este link.',
                    style: mu,
                  ),
                ),
              ],
              data: (link) {
                final player = ref.read(playerProvider.notifier);
                final shown = link.tracks.length;
                return [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final size = constraints.maxWidth.clamp(
                          0.0,
                          BergaSizes.playlistCoverMaxHeight,
                        );
                        return Align(
                          alignment: Alignment.centerLeft,
                          child: link.coverUrl == null
                              ? Cover.playlist(size: size, initialSize: 60)
                              : Cover(
                                  seed: url,
                                  title: link.title,
                                  size: size,
                                  image: imageFor(link.coverUrl),
                                ),
                        );
                      },
                    ),
                  ),
                  ScreenTitle(link.title, bottom: 4),
                  Text(
                    [
                      if (link.subtitle.isNotEmpty) link.subtitle,
                      '$shown músicas',
                      totalDuration(link.tracks.map((t) => t.durationSeconds)),
                      link.sourceLabel,
                    ].join(' · '),
                    style: mu,
                  ),
                  if (link.total > shown)
                    Text('Mostrando $shown de ${link.total}', style: mu),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    child: Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        PlayButton(
                          playing: false,
                          onPressed: link.tracks.isEmpty
                              ? null
                              : () => player.playList(
                                  link.tracks,
                                  0,
                                  context: link.title,
                                ),
                        ),
                        PrimaryButton(
                          label: 'Adicionar músicas à playlist',
                          onPressed: () => addToPlaylist(
                            context,
                            ref,
                            tracks: link.tracks,
                            suggestedName: link.title,
                          ),
                        ),
                      ],
                    ),
                  ),
                  for (final (index, t) in link.tracks.indexed)
                    TrackRow(
                      key: ValueKey('${t.id}-$index'),
                      id: t.id,
                      title: t.title,
                      artist: t.artist,
                      cover: coverImage(t),
                      playing: t.id == playingId,
                      onTap: () => player.playList(
                        link.tracks,
                        index,
                        context: link.title,
                      ),
                      onMore: () => showTrackMenu(context, ref, t),
                      onQueue: () => queueTrack(context, ref, t),
                    ),
                ];
              },
            ),
          ],
        ),
      ),
    );
  }
}
