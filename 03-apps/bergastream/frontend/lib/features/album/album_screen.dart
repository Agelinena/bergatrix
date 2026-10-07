import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/player/player_texts.dart';
import 'package:go_router/go_router.dart';

import '../../app/catalog_navigation.dart';
import '../../core/network/api_error.dart';
import '../../core/platform/app_layout.dart';
import '../../core/theme/berga_colors.dart';
import '../../core/theme/berga_sizes.dart';
import '../../core/theme/berga_text.dart';
import '../../core/utils/format.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/catalog.dart';
import '../artist/artist_tracks_pager.dart';
import '../library/add_to_playlist.dart';
import '../player/player_controller.dart';
import '../player/track_menu.dart';

/// Página do álbum (Seção 6.7): capa, nome, artista, ano e duração total;
/// play e aleatório; faixas numeradas; "Buscar neste álbum".
class AlbumScreen extends ConsumerStatefulWidget {
  const AlbumScreen({super.key, required this.provider, required this.id});

  final String provider;
  final String id;

  @override
  ConsumerState<AlbumScreen> createState() => _AlbumScreenState();
}

class _AlbumScreenState extends ConsumerState<AlbumScreen> {
  String _filter = '';

  (String, String) get _key => (widget.provider, widget.id);

  void _play(AlbumPage album, {required bool shuffle, int index = 0}) {
    final player = ref.read(playerProvider.notifier);
    if (ref.read(playerProvider).shuffle != shuffle) player.toggleShuffle();
    player.playList(album.tracks, index, context: album.title);
  }

  @override
  Widget build(BuildContext context) {
    final c = BergaColors.of(context);
    final mu = BergaText.secondary.copyWith(color: c.mu);
    final page = ref.watch(albumPageProvider(_key));
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: AppLayout.screenPadding(context),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: GestureDetector(
                onTap: () => context.canPop() ? context.pop() : null,
                child: Text('‹ Voltar', style: mu),
              ),
            ),
            ...page.when(
              loading: () => [
                Padding(
                  padding: const EdgeInsets.only(top: 20),
                  child: Text('Carregando álbum…', style: mu),
                ),
              ],
              error: (e, _) => [
                Padding(
                  padding: const EdgeInsets.only(top: 20, bottom: 12),
                  child: Text(
                    e is ApiException ? e.message : 'Álbum não encontrado.',
                    style: mu,
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: AppChip(
                    label: 'Tentar de novo',
                    onTap: () => ref.invalidate(albumPageProvider(_key)),
                  ),
                ),
              ],
              data: (album) => _content(context, album),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _content(BuildContext context, AlbumPage album) {
    final c = BergaColors.of(context);
    final mu = BergaText.secondary.copyWith(color: c.mu);
    final shuffle = ref.watch(playerProvider.select((s) => s.shuffle));
    final playingId = ref.watch(
      playerProvider.select((s) => s.current?.track.id),
    );
    final tracks = filterTracks(album.tracks, _filter);

    return [
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Cover(
          seed: album.title,
          title: album.title,
          size: BergaSizes.playlistCoverMaxHeight,
          image: imageFor(album.imageUrl),
        ),
      ),
      ScreenTitle(album.title, bottom: 4),
      GestureDetector(
        onTap: album.artistId == null
            ? null
            : () => openArtist(context, album.provider, album.artistId!),
        child: Text(
          [
            album.artist,
            ?album.year,
            '${album.tracks.length} músicas',
            totalDuration(album.tracks.map((t) => t.durationSeconds)),
          ].where((s) => s.isNotEmpty).join(' · '),
          style: mu,
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Wrap(
          spacing: 10,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            PlayButton(
              playing: false,
              onPressed: () => _play(album, shuffle: false),
            ),
            AppChip(
              label: 'Aleatório',
              icon: Icons.shuffle,
              active: shuffle,
              onTap: () => _play(album, shuffle: true),
            ),
            AppChip(
              label: 'Adicionar à playlist',
              onTap: () => addToPlaylist(
                context,
                ref,
                tracks: album.tracks,
                suggestedName: album.title,
              ),
            ),
          ],
        ),
      ),
      AppTextField(
        hint: 'Buscar neste álbum',
        onChanged: (v) => setState(() => _filter = v),
      ),
      const SizedBox(height: 10),
      if (tracks.isEmpty && _filter.isNotEmpty)
        Text('Nada encontrado para "$_filter".', style: mu),
      for (final t in tracks)
        TrackRow(
          key: ValueKey(t.id),
          id: t.id,
          title: t.title,
          artist: t.artist,
          number: album.tracks.indexOf(t) + 1,
          playing: t.id == playingId,
          onTap: () => _play(
            album,
            shuffle: ref.read(playerProvider).shuffle,
            index: album.tracks.indexOf(t),
          ),
          onMore: () => showTrackMenu(
            context,
            ref,
            t,
            onGoToArtist: goToArtistOf(context, t),
          ),
          onQueue: () => queueTrack(context, ref, t),
        ),
    ];
  }
}
