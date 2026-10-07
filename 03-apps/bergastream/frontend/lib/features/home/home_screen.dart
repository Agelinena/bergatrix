import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/routes.dart';
import '../../core/platform/app_layout.dart';
import '../../core/theme/berga_colors.dart';
import '../../core/theme/berga_sizes.dart';
import '../../core/theme/berga_text.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/stats.dart';
import '../auth/auth_texts.dart';
import '../auth/session.dart';
import '../player/player_controller.dart';
import '../player/player_texts.dart';
import '../player/track_menu.dart';
import 'greeting.dart';
import 'home_providers.dart';

/// Aba Início (Seção 6.2): métricas reais do histórico do mês. Sem servidor
/// mostra a última resposta guardada; sem nada guardado, o estado vazio.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key, this.now});

  /// Hora usada na saudação (para testes); padrão: agora.
  final DateTime? now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = BergaColors.of(context);
    final mu = BergaText.secondary.copyWith(color: c.mu);
    final stats = ref.watch(homeStatsProvider);
    final online = ref.watch(sessionProvider.select((s) => s.canUseServer));
    final data = stats.value;

    return RefreshIndicator(
      color: c.gr,
      onRefresh: () => ref.refresh(homeStatsProvider.future),
      child: ListView(
        key: const PageStorageKey('home'),
        padding: AppLayout.screenPadding(context),
        children: [
          Text(greetingFor(now ?? DateTime.now()), style: mu),
          const ScreenTitle('Seu som'),
          if (data == null)
            Text(
              stats.isLoading && online ? 'Carregando…' : AuthTexts.emptyHome,
              style: mu,
            )
          else
            ..._content(context, ref, data),
        ],
      ),
    );
  }

  List<Widget> _content(BuildContext context, WidgetRef ref, ListeningStats s) {
    final c = BergaColors.of(context);
    final player = ref.read(playerProvider.notifier);
    final tracks = [for (final t in s.topTracks) t.track];
    final playingId = ref.watch(
      playerProvider.select((p) => p.current?.track.id),
    );
    void search(String term) =>
        context.go('${AppRoutes.search}?q=${Uri.encodeQueryComponent(term)}');

    return [
      Row(
        spacing: BergaSizes.statGap,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: StatCard(
              value: formatListening(s.secondsMonth),
              label: 'ouvidas este mês',
            ),
          ),
          Expanded(
            child: StatCard(
              value: '${s.distinctTracksMonth}',
              label: 'músicas diferentes',
            ),
          ),
        ],
      ),
      if (s.isEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 20),
          child: Text(
            'Ouça músicas para ver aqui os artistas, faixas e álbuns que você '
            'mais escuta.',
            style: BergaText.secondary.copyWith(color: c.mu),
          ),
        ),
      if (s.topArtists.isNotEmpty) ...[
        const SectionTitle('Artistas que você mais ouve'),
        HorizontalShelf(
          children: [
            for (final a in s.topArtists)
              ArtistCircle(
                id: a.name,
                name: a.name,
                image: imageFor(a.imageUrl),
                onTap: () => search(a.name),
              ),
          ],
        ),
      ],
      if (tracks.isNotEmpty) ...[
        const SectionTitle('Mais tocadas'),
        for (final (i, t) in tracks.take(4).indexed)
          TrackRow(
            key: ValueKey(t.id),
            id: t.id,
            title: t.title,
            artist: t.artist,
            cover: coverImage(t),
            playing: t.id == playingId,
            onTap: () => player.playList(tracks, i, context: 'Mais tocadas'),
            onMore: () => showTrackMenu(context, ref, t),
            onQueue: () => queueTrack(context, ref, t),
          ),
      ],
      if (s.topAlbums.isNotEmpty) ...[
        const SectionTitle('Álbuns'),
        HorizontalShelf(
          children: [
            for (final a in s.topAlbums)
              AlbumTile(
                id: '${a.artist}:${a.title}',
                title: a.title,
                image: imageFor(a.coverUrl),
                onTap: () => search('${a.title} ${a.artist}'),
              ),
          ],
        ),
      ],
    ];
  }
}
