import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/catalog_navigation.dart';
import '../../app/routes.dart';
import '../../core/network/api_error.dart';
import '../../core/platform/app_layout.dart';
import '../../core/theme/berga_colors.dart';
import '../../core/theme/berga_sizes.dart';
import '../../core/theme/berga_text.dart';
import '../../core/utils/links.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/search_full.dart';
import '../../data/repositories/search_history_repository.dart';
import '../../data/repositories/search_repository.dart';
import '../auth/auth_texts.dart';
import '../auth/session.dart';
import '../library/add_to_playlist.dart';
import '../player/player_controller.dart';
import '../player/player_texts.dart';
import '../player/track_menu.dart';
import '../../data/local/database.dart';
import 'search_providers.dart';

/// Aba Buscar (Seção 6.3): Artistas, Álbuns e Músicas do Spotify ou do YT
/// Music, buscas recentes e links colados (faixa ou playlist/álbum).
///
/// Sem servidor (Seção 2.4) a busca é local (nas músicas baixadas), os chips
/// somem e aparece o convite para entrar.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key, this.initialLink, this.initialQuery});

  /// Link vindo do "Link do app" (`/buscar?link=`).
  final String? initialLink;

  /// Termo vindo do Início (artista ou álbum mais ouvido): `/buscar?q=`.
  final String? initialQuery;

  static const debounce = Duration(milliseconds: 400);

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  late final _controller = TextEditingController(
    text: widget.initialLink ?? widget.initialQuery ?? '',
  );
  SearchSource _source = SearchSource.spotify;
  Timer? _debounce;

  /// Termo efetivamente buscado (depois da espera).
  late String _query =
      (widget.initialLink ?? widget.initialQuery)?.trim() ?? '';

  @override
  void didUpdateWidget(SearchScreen old) {
    super.didUpdateWidget(old);
    final link = widget.initialLink;
    if (link != null && link != old.initialLink) _searchNow(link);
    final query = widget.initialQuery;
    if (query != null && query != old.initialQuery) _searchNow(query);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    _debounce?.cancel();
    final query = text.trim();
    if (query.isEmpty) {
      setState(() => _query = '');
      return;
    }
    setState(() {});
    _debounce = Timer(
      SearchScreen.debounce,
      () => setState(() => _query = query),
    );
  }

  void _searchNow(String term) {
    _debounce?.cancel();
    _controller.text = term;
    setState(() => _query = term.trim());
  }

  /// Guarda o termo nas buscas recentes (ao usar um resultado ou confirmar).
  void _remember() {
    if (_query.isNotEmpty) ref.read(searchHistoryProvider.notifier).add(_query);
  }

  void _setSource(SearchSource source) => setState(() => _source = source);

  @override
  Widget build(BuildContext context) {
    final canUseServer = ref.watch(
      sessionProvider.select((s) => s.canUseServer),
    );
    return ListView(
      key: const PageStorageKey('search'),
      padding: AppLayout.screenPadding(context),
      children: [
        const ScreenTitle('Buscar'),
        AppTextField(
          hint: canUseServer
              ? 'Músicas, artistas, álbuns ou link'
              : 'Buscar nas músicas baixadas',
          controller: _controller,
          onChanged: _onChanged,
          onSubmitted: (text) {
            _searchNow(text);
            _remember();
          },
          textInputAction: TextInputAction.search,
        ),
        if (!canUseServer) ...[
          // Logado com o servidor fora, o aviso no topo já explica.
          if (!ref.watch(sessionProvider.select((s) => s.isLoggedIn)))
            const _EnterCard(),
          ..._localBody(context),
        ] else ...[
          // Só a margem de cima: no protótipo a de baixo (10) colapsa com a
          // do conteúdo seguinte, que já tem a sua (h2 20, cartão 10, aviso 20).
          if (!isLink(_controller.text))
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(
                spacing: BergaSizes.chipGap,
                children: [
                  for (final source in SearchSource.values)
                    AppChip(
                      label: source.label,
                      active: _source == source,
                      onTap: () => _setSource(source),
                    ),
                ],
              ),
            ),
          ..._serverBody(context),
        ],
      ],
    );
  }

  List<Widget> _serverBody(BuildContext context) {
    final c = BergaColors.of(context);
    final mu = BergaText.secondary.copyWith(color: c.mu);

    if (_query.isEmpty) {
      final history = ref.watch(searchHistoryProvider);
      return [
        if (history.isNotEmpty) ...[
          const SectionTitle('Buscas recentes'),
          for (final term in history)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _searchNow(term),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: BergaSizes.trackPaddingVertical,
                ),
                child: Row(
                  spacing: BergaSizes.trackGap,
                  children: [
                    Icon(Icons.history, size: 13, color: c.mu),
                    Expanded(
                      child: Text(
                        term,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: BergaText.body.copyWith(color: c.tx),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
        Padding(
          padding: EdgeInsets.only(top: history.isEmpty ? 20 : 14),
          child: Text(
            'Cole um link do Spotify, Deezer ou YouTube para trazer a música '
            'ou playlist exata.',
            style: mu,
          ),
        ),
      ];
    }

    if (isLink(_query)) return _linkBody(context);

    final result = ref.watch(searchResultsProvider((_query, _source)));
    return result.when(
      loading: () => [_loading(context)],
      error: (e, _) => _error(
        context,
        e,
        () => ref.invalidate(searchResultsProvider((_query, _source))),
      ),
      data: (data) => data.isEmpty
          ? [
              Padding(
                padding: const EdgeInsets.only(top: 20),
                child: Text(
                  'Nada encontrado para "$_query". Tente outro nome ou cole '
                  'um link.',
                  style: mu,
                ),
              ),
            ]
          : _results(context, data),
    );
  }

  List<Widget> _results(BuildContext context, FullSearchResult data) {
    final player = ref.read(playerProvider.notifier);
    final playingId = ref.watch(
      playerProvider.select((s) => s.current?.track.id),
    );
    return [
      if (data.artists.isNotEmpty) ...[
        const SectionTitle('Artistas'),
        HorizontalShelf(
          children: [
            for (final a in data.artists)
              ArtistCircle(
                id: a.id,
                name: a.name,
                image: imageFor(a.imageUrl),
                onTap: () {
                  _remember();
                  openArtist(context, a.provider, a.externalId);
                },
              ),
          ],
        ),
      ],
      if (data.albums.isNotEmpty) ...[
        const SectionTitle('Álbuns'),
        HorizontalShelf(
          children: [
            for (final a in data.albums)
              AlbumTile(
                id: a.id,
                title: a.title,
                image: imageFor(a.imageUrl),
                onTap: () {
                  _remember();
                  openAlbum(context, a.provider, a.externalId);
                },
              ),
          ],
        ),
      ],
      if (data.tracks.isNotEmpty) ...[
        const SectionTitle('Músicas'),
        for (final (index, r) in data.tracks.indexed)
          TrackRow(
            key: ValueKey(r.id),
            id: r.id,
            title: r.title,
            artist: r.artist,
            playing: r.id == playingId,
            cover: coverImage(r),
            onTap: () {
              _remember();
              player.playList(data.tracks, index, context: 'Busca');
            },
            onMore: () => showTrackMenu(
              context,
              ref,
              r,
              onGoToAlbum: goToAlbumOf(context, r),
              onGoToArtist: goToArtistOf(context, r),
            ),
            onQueue: () => queueTrack(context, ref, r),
          ),
      ],
    ];
  }

  List<Widget> _linkBody(BuildContext context) {
    final resolved = ref.watch(resolvedLinkProvider(_query));
    return resolved.when(
      loading: () => [_loading(context, text: 'Abrindo link…')],
      error: (e, _) => _error(
        context,
        e,
        () => ref.invalidate(resolvedLinkProvider(_query)),
      ),
      data: (link) {
        if (link.isTrack && link.tracks.isNotEmpty) {
          final t = link.tracks.single;
          return [
            const SectionTitle('Música'),
            TrackRow(
              id: t.id,
              title: t.title,
              artist: t.artist,
              cover: coverImage(t),
              playing:
                  ref.watch(
                    playerProvider.select((s) => s.current?.track.id),
                  ) ==
                  t.id,
              onTap: () {
                _remember();
                ref
                    .read(playerProvider.notifier)
                    .playList(link.tracks, 0, context: 'Busca');
              },
              onMore: () => showTrackMenu(context, ref, t),
              onQueue: () => queueTrack(context, ref, t),
            ),
          ];
        }
        return [_ImportedCard(link: link, url: _query, onOpen: _remember)];
      },
    );
  }

  Widget _loading(BuildContext context, {String text = 'Buscando…'}) {
    final c = BergaColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Row(
        spacing: 10,
        children: [
          SizedBox.square(
            dimension: 14,
            child: CircularProgressIndicator(strokeWidth: 2, color: c.gr),
          ),
          Text(text, style: BergaText.secondary.copyWith(color: c.mu)),
        ],
      ),
    );
  }

  List<Widget> _error(BuildContext context, Object e, VoidCallback retry) {
    final c = BergaColors.of(context);
    final message = switch (e) {
      ApiException(statusCode: 400) =>
        'Link não reconhecido. Use um link de música, álbum ou playlist do '
            'Spotify, Deezer ou YouTube.',
      ApiException(statusCode: 404) =>
        'Não foi possível abrir este link. Ele pode ser privado.',
      ApiException(:final message) => message,
      _ => ApiErrorKind.requisicao.message,
    };
    return [
      Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 12),
        child: Text(message, style: BergaText.secondary.copyWith(color: c.mu)),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: AppChip(label: 'Tentar de novo', onTap: retry),
      ),
    ];
  }

  /// Busca local (Seção 2.4): nas músicas baixadas no aparelho.
  List<Widget> _localBody(BuildContext context) {
    final query = _controller.text.trim();
    if (query.isEmpty) return const [];
    final c = BergaColors.of(context);
    final found = ref.watch(localSearchProvider(query)).value ?? const [];
    if (found.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.only(top: 20),
          child: Text(
            'Nada encontrado para "$query" nas músicas baixadas.',
            style: BergaText.secondary.copyWith(color: c.mu),
          ),
        ),
      ];
    }
    final tracks = [for (final t in found) t.asResult];
    return [
      const SectionTitle('Músicas baixadas'),
      for (final (index, t) in found.indexed)
        TrackRow(
          key: ValueKey(t.id),
          id: t.id,
          title: t.title,
          artist: t.artist,
          cover: imageFor(
            t.coverPath != null
                ? Uri.file(t.coverPath!).toString()
                : t.coverUrl,
          ),
          downloadState: DownloadState.baixada,
          onTap: () => ref
              .read(playerProvider.notifier)
              .playList(tracks, index, context: 'Busca'),
          onMore: () => showTrackMenu(context, ref, tracks[index]),
          onQueue: () => queueTrack(context, ref, tracks[index]),
        ),
    ];
  }
}

/// Cartão do link de playlist ou álbum (Seção 6.3).
class _ImportedCard extends ConsumerWidget {
  const _ImportedCard({
    required this.link,
    required this.url,
    required this.onOpen,
  });

  final ResolvedLink link;
  final String url;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = BergaColors.of(context);
    final total = link.total;
    return GestureDetector(
      onTap: () {
        onOpen();
        context.push(AppRoutes.importedLink(url));
      },
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              spacing: 10,
              children: [
                link.coverUrl == null
                    ? const Cover.playlist(size: 56)
                    : Cover(
                        seed: url,
                        title: link.title,
                        size: 56,
                        image: imageFor(link.coverUrl),
                      ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        link.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: BergaText.trackTitle.copyWith(color: c.tx),
                      ),
                      Text(
                        '${total == 1 ? '1 música' : '$total músicas'} · '
                        '${link.sourceLabel}',
                        style: BergaText.secondary.copyWith(color: c.mu),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
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
    );
  }
}

/// Convite para entrar, no lugar dos chips (Seção 2.4).
class _EnterCard extends StatelessWidget {
  const _EnterCard();

  @override
  Widget build(BuildContext context) {
    final c = BergaColors.of(context);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AuthTexts.enterToSearch,
            style: BergaText.trackTitle.copyWith(color: c.tx),
          ),
          const SizedBox(height: 12),
          PrimaryButton(
            label: 'Entrar',
            onPressed: () => context.go(AppRoutes.login),
          ),
        ],
      ),
    );
  }
}
