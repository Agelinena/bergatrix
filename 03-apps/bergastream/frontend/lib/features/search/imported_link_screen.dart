import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/catalog_navigation.dart';
import '../../core/network/api_error.dart';
import '../../core/platform/app_layout.dart';
import '../../core/theme/berga_colors.dart';
import '../../core/theme/berga_sizes.dart';
import '../../core/theme/berga_text.dart';
import '../../core/widgets/widgets.dart';
import '../artist/artist_tracks_pager.dart';
import '../library/add_to_playlist.dart';
import '../player/player_controller.dart';
import '../player/player_texts.dart';
import '../player/track_menu.dart';
import 'search_providers.dart';
import '../../core/utils/format.dart';

/// Playlist ou álbum de um link colado (Seção 6.7, "Playlist importada"):
/// mesma cara do detalhe de playlist, com "Adicionar músicas à playlist" no
/// topo.
class ImportedLinkScreen extends ConsumerStatefulWidget {
  const ImportedLinkScreen({super.key, required this.url});

  final String url;

  @override
  ConsumerState<ImportedLinkScreen> createState() => _ImportedLinkScreenState();
}

class _ImportedLinkScreenState extends ConsumerState<ImportedLinkScreen> {
  String _filter = '';
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  String get url => widget.url;

  @override
  Widget build(BuildContext context) {
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
                final tracks = filterTracks(link.tracks, _filter);
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
                          label: link.isTrack
                              ? 'Adicionar à playlist'
                              : 'Importar',
                          onPressed: () => importLink(context, ref, link),
                        ),
                        // Os mesmos botões de uma playlist (o que dá sem
                        // importar): aleatório, fila e compartilhar.
                        if (link.tracks.length > 1)
                          AppChip(
                            label: 'Aleatório',
                            icon: Icons.shuffle,
                            onTap: () => player.playList(
                              link.tracks,
                              Random().nextInt(link.tracks.length),
                              context: link.title,
                              shuffle: true,
                            ),
                          ),
                        if (link.tracks.isNotEmpty)
                          AppChip(
                            label: 'Adicionar à fila',
                            icon: Icons.queue_music,
                            onTap: () async {
                              await player.addAllToQueue(link.tracks);
                              if (context.mounted) {
                                AppToast.show(
                                  context,
                                  '${link.tracks.length} músicas na fila',
                                );
                              }
                            },
                          ),
                        AppChip(
                          label: 'Compartilhar',
                          icon: Icons.share,
                          onTap: () => shareText(
                            context,
                            ref,
                            link.externalUrl,
                            copiedMessage: 'Link copiado',
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (link.tracks.length > 8)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: AppTextField(
                        hint: 'Buscar na lista',
                        controller: _search,
                        onChanged: (v) => setState(() => _filter = v),
                        onClear: () => setState(() => _filter = ''),
                      ),
                    ),
                  if (tracks.isEmpty && _filter.isNotEmpty)
                    Text('Nada encontrado para "$_filter".', style: mu),
                  for (final (index, t) in tracks.indexed)
                    TrackRow(
                      key: ValueKey('${t.id}-$index'),
                      id: t.id,
                      title: t.title,
                      artist: t.artist,
                      cover: coverImage(t),
                      playing: t.id == playingId,
                      onTap: () =>
                          player.playList(tracks, index, context: link.title),
                      onMore: () => showTrackMenu(
                        context,
                        ref,
                        t,
                        onGoToAlbum: goToAlbumOf(context, t),
                        onGoToArtist: goToArtistOf(context, t),
                      ),
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
