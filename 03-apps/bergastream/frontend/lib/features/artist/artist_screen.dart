import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
import '../../data/models/search_result.dart';
import '../player/player_controller.dart';
import '../player/player_texts.dart';
import '../player/track_menu.dart';
import 'artist_tracks_pager.dart';

enum ArtistTab { populares, albuns, todas }

/// Página do artista (Seção 6.7): foto, nome e seguidores; play e
/// aleatório; abas Populares, Álbuns e Todas as músicas (paginada, com
/// rolagem infinita); "Buscar neste artista" filtra a aba atual.
class ArtistScreen extends ConsumerStatefulWidget {
  const ArtistScreen({super.key, required this.provider, required this.id});

  final String provider;
  final String id;

  @override
  ConsumerState<ArtistScreen> createState() => _ArtistScreenState();
}

class _ArtistScreenState extends ConsumerState<ArtistScreen> {
  ArtistTab _tab = ArtistTab.populares;
  String _filter = '';
  final _scroll = ScrollController();

  (String, String) get _key => (widget.provider, widget.id);

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Rolagem infinita: perto do fim, pede a próxima página.
  void _maybeLoadMore() {
    if (_tab != ArtistTab.todas || !_scroll.hasClients) return;
    if (_scroll.position.extentAfter < 600) {
      ref.read(artistTracksProvider(_key).notifier).loadMore();
    }
  }

  void _selectTab(ArtistTab tab) {
    setState(() => _tab = tab);
    if (tab == ArtistTab.todas) {
      final pager = ref.read(artistTracksProvider(_key));
      if (pager.items.isEmpty) {
        ref.read(artistTracksProvider(_key).notifier).loadMore();
      }
    }
  }

  void _play(ArtistPage artist, {required bool shuffle}) {
    final tracks = _tab == ArtistTab.todas
        ? ref.read(artistTracksProvider(_key)).items
        : artist.topTracks;
    if (tracks.isEmpty) return;
    final player = ref.read(playerProvider.notifier);
    if (ref.read(playerProvider).shuffle != shuffle) player.toggleShuffle();
    player.playList(tracks, 0, context: artist.name);
  }

  @override
  Widget build(BuildContext context) {
    final c = BergaColors.of(context);
    final mu = BergaText.secondary.copyWith(color: c.mu);
    final page = ref.watch(artistPageProvider(_key));
    // Mantém o paginador vivo enquanto a tela existir (é autoDispose): sem
    // isso, a página pedida ao trocar de aba se perdia.
    ref.watch(artistTracksProvider(_key));

    return Scaffold(
      body: SafeArea(
        child: ListView(
          controller: _scroll,
          padding: AppLayout.screenPadding(context),
          children: [
            const _BackLink(),
            ...page.when(
              loading: () => [
                Padding(
                  padding: const EdgeInsets.only(top: 20),
                  child: Text('Carregando artista…', style: mu),
                ),
              ],
              error: (e, _) => [
                Padding(
                  padding: const EdgeInsets.only(top: 20, bottom: 12),
                  child: Text(
                    e is ApiException ? e.message : 'Artista não encontrado.',
                    style: mu,
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: AppChip(
                    label: 'Tentar de novo',
                    onTap: () => ref.invalidate(artistPageProvider(_key)),
                  ),
                ),
              ],
              data: (artist) => _content(context, artist),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _content(BuildContext context, ArtistPage artist) {
    final c = BergaColors.of(context);
    final mu = BergaText.secondary.copyWith(color: c.mu);
    final audience = artist.followers != null
        ? '${compactCount(artist.followers!)} de seguidores'
        : artist.followersText != null
        ? '${artist.followersText} de inscritos'
        : null;
    final shuffle = ref.watch(playerProvider.select((s) => s.shuffle));

    return [
      Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 14),
        child: Center(
          child: Cover(
            seed: artist.name,
            title: artist.name,
            size: 160,
            circle: true,
            image: imageFor(artist.imageUrl),
          ),
        ),
      ),
      ScreenTitle(artist.name, bottom: 2),
      if (audience != null) Text(audience, style: mu),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Row(
          spacing: 10,
          children: [
            PlayButton(
              playing: false,
              onPressed: () => _play(artist, shuffle: false),
            ),
            AppChip(
              label: 'Aleatório',
              icon: Icons.shuffle,
              active: shuffle,
              onTap: () => _play(artist, shuffle: true),
            ),
          ],
        ),
      ),
      AppTextField(
        hint: 'Buscar neste artista',
        onChanged: (v) => setState(() => _filter = v),
      ),
      Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Wrap(
          spacing: BergaSizes.chipGap,
          runSpacing: 8,
          children: [
            for (final (tab, label) in [
              (ArtistTab.populares, 'Populares'),
              (ArtistTab.albuns, 'Álbuns'),
              (ArtistTab.todas, 'Todas as músicas'),
            ])
              AppChip(
                label: label,
                active: _tab == tab,
                onTap: () => _selectTab(tab),
              ),
          ],
        ),
      ),
      const SizedBox(height: 10),
      ...switch (_tab) {
        ArtistTab.populares => _trackList(
          context,
          filterTracks(artist.topTracks, _filter),
          artist.name,
        ),
        ArtistTab.albuns => [_albums(context, artist)],
        ArtistTab.todas => _allTracks(context, artist),
      },
    ];
  }

  List<Widget> _trackList(
    BuildContext context,
    List<SearchResult> tracks,
    String contextName,
  ) {
    final playingId = ref.watch(
      playerProvider.select((s) => s.current?.track.id),
    );
    final player = ref.read(playerProvider.notifier);
    if (tracks.isEmpty && _filter.isNotEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(
            'Nada encontrado para "$_filter".',
            style: BergaText.secondary.copyWith(
              color: BergaColors.of(context).mu,
            ),
          ),
        ),
      ];
    }
    return [
      for (final (index, t) in tracks.indexed)
        TrackRow(
          key: ValueKey('${t.id}-$index'),
          id: t.id,
          title: t.title,
          artist: t.album.isEmpty ? t.artist : t.album,
          cover: coverImage(t),
          playing: t.id == playingId,
          onTap: () => player.playList(tracks, index, context: contextName),
          onMore: () => showTrackMenu(
            context,
            ref,
            t,
            onGoToAlbum: goToAlbumOf(context, t),
          ),
          onQueue: () => queueTrack(context, ref, t),
        ),
    ];
  }

  Widget _albums(BuildContext context, ArtistPage artist) {
    final q = _filter.trim().toLowerCase();
    final albums = [
      for (final a in artist.albums)
        if (q.isEmpty || a.title.toLowerCase().contains(q)) a,
    ];
    return Wrap(
      spacing: BergaSizes.shelfGap,
      runSpacing: 16,
      children: [
        for (final a in albums)
          AlbumTile(
            id: a.id,
            title: a.year == null ? a.title : '${a.title} · ${a.year}',
            image: imageFor(a.imageUrl),
            onTap: () => openAlbum(context, a.provider, a.externalId),
          ),
      ],
    );
  }

  List<Widget> _allTracks(BuildContext context, ArtistPage artist) {
    final c = BergaColors.of(context);
    final mu = BergaText.secondary.copyWith(color: c.mu);
    final state = ref.watch(artistTracksProvider(_key));
    final filtered = filterTracks(state.items, _filter);
    return [
      if (state.total != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            '${state.items.length} de ${state.total} músicas',
            style: mu,
          ),
        ),
      ..._trackList(context, filtered, artist.name),
      if (state.error != null) ...[
        Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 8),
          child: Text(state.error!.message, style: mu),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: AppChip(
            label: 'Tentar de novo',
            onTap: () =>
                ref.read(artistTracksProvider(_key).notifier).loadMore(),
          ),
        ),
      ] else if (state.hasMore)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Center(
            child: state.loading
                ? SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: c.gr,
                    ),
                  )
                // Reserva se a rolagem não disparar (lista curta em tela alta).
                : AppChip(
                    label: 'Carregar mais',
                    onTap: () => ref
                        .read(artistTracksProvider(_key).notifier)
                        .loadMore(),
                  ),
          ),
        ),
    ];
  }
}

class _BackLink extends StatelessWidget {
  const _BackLink();

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: GestureDetector(
        onTap: () => context.canPop() ? context.pop() : null,
        child: Text(
          '‹ Voltar',
          style: BergaText.secondary.copyWith(
            color: BergaColors.of(context).mu,
          ),
        ),
      ),
    );
  }
}
