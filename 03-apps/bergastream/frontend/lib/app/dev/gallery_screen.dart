import 'package:flutter/material.dart';

import '../../core/theme/berga_colors.dart';
import '../../core/theme/berga_sizes.dart';
import '../../core/theme/berga_text.dart';
import '../../core/theme/berga_theme.dart';
import '../../core/widgets/widgets.dart';

/// Faixas fictícias do protótipo: (id, título, artista, álbum).
const _tracks = [
  ('t1', 'Blinding Lights', 'The Weeknd', 'After Hours'),
  ('t2', 'Levitating', 'Dua Lipa', 'Future Nostalgia'),
  ('t3', 'Bohemian Rhapsody', 'Queen', 'A Night at the Opera'),
  ('t4', 'Smells Like Teen Spirit', 'Nirvana', 'Nevermind'),
  ('t5', 'Hotel California', 'Eagles', 'Hotel California'),
  ('t6', 'Get Lucky', 'Daft Punk', 'Random Access Memories'),
  ('t7', 'Creep', 'Radiohead', 'Pablo Honey'),
  ('t8', 'Redbone', 'Childish Gambino', 'Awaken, My Love!'),
];

/// Galeria de todos os componentes (rota `/dev/gallery`, só em debug).
/// Os chips no topo forçam o tema escuro ou claro.
class GalleryScreen extends StatefulWidget {
  const GalleryScreen({super.key});

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  bool? _dark;
  bool _shuffle = true;
  String _source = 'Spotify';

  @override
  Widget build(BuildContext context) {
    final dark = _dark ?? Theme.of(context).brightness == Brightness.dark;
    return Theme(
      data: dark ? BergaTheme.dark : BergaTheme.light,
      child: Builder(builder: _buildPage),
    );
  }

  Widget _buildPage(BuildContext context) {
    final c = BergaColors.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final mu = BergaText.secondary.copyWith(color: c.mu);

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: ListView(
          padding: BergaSizes.screenPadding,
          children: [
            const ScreenTitle('Galeria'),
            Text('Componentes do Passo 1 (só em debug).', style: mu),
            _chips([
              AppChip(
                label: 'Escuro',
                active: dark,
                onTap: () => setState(() => _dark = true),
              ),
              AppChip(
                label: 'Claro',
                active: !dark,
                onTap: () => setState(() => _dark = false),
              ),
            ]),
            const SectionTitle('Cores'),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _swatch(context, 'bg', c.bg),
                _swatch(context, 'card', c.card),
                _swatch(context, 'tx', c.tx),
                _swatch(context, 'mu', c.mu),
                _swatch(context, 'ac', c.ac),
                _swatch(context, 'gr', c.gr),
                _swatch(context, 'on', c.on),
              ],
            ),
            const SectionTitle('Tipografia'),
            Text('Título de tela', style: BergaText.h1.copyWith(color: c.tx)),
            Text('Título de seção', style: BergaText.h2.copyWith(color: c.tx)),
            Text('Corpo do texto', style: BergaText.body.copyWith(color: c.tx)),
            Text(
              'Título de faixa',
              style: BergaText.trackTitle.copyWith(color: c.tx),
            ),
            Text('Texto secundário', style: mu),
            const SectionTitle('Capas'),
            const Row(
              spacing: 12,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Cover(seed: 't1', title: 'Blinding Lights', size: 46),
                Cover(seed: 't6', title: 'Get Lucky', size: 56),
                Cover.playlist(size: 56),
                Cover(seed: 'Queen', title: 'Queen', size: 96, circle: true),
              ],
            ),
            const SectionTitle('Métricas'),
            const Row(
              spacing: BergaSizes.statGap,
              children: [
                Expanded(
                  child: StatCard(value: '42 h', label: 'ouvidas este mês'),
                ),
                Expanded(
                  child: StatCard(value: '318', label: 'músicas diferentes'),
                ),
              ],
            ),
            const SectionTitle('Chips e botões'),
            _chips([
              for (final source in ['Spotify', 'YT Music'])
                AppChip(
                  label: source,
                  active: _source == source,
                  onTap: () => setState(() => _source = source),
                ),
              AppChip(
                label: 'Aleatório',
                icon: Icons.shuffle,
                active: _shuffle,
                onTap: () => setState(() => _shuffle = !_shuffle),
              ),
              const AppChip(label: 'Adição'),
            ]),
            Row(
              spacing: 10,
              children: [
                PrimaryButton(
                  label: 'Nova playlist',
                  onPressed: () => AppToast.show(context, 'Nova playlist'),
                ),
                const PlayButton(playing: false),
                const PlayButton(playing: true),
                const PlayButton(
                  playing: false,
                  size: BergaSizes.playButtonLarge,
                ),
              ],
            ),
            const SectionTitle('Campo de texto'),
            const AppTextField(hint: 'Músicas, artistas, álbuns ou link'),
            const SectionTitle('Linhas de faixa'),
            _row(context, 0),
            _row(context, 1, playing: true),
            _row(
              context,
              2,
              addedBy: 'Ana',
              downloadState: DownloadState.baixada,
            ),
            _row(
              context,
              5,
              addedBy: 'Pedro',
              downloadState: DownloadState.baixando,
              progress: 0.4,
            ),
            _row(context, 6, downloadState: DownloadState.naFila),
            _row(context, 7, downloadState: DownloadState.falhou),
            const SectionTitle('Artistas que você mais ouve'),
            HorizontalShelf(
              children: [
                for (final t in _tracks.take(6))
                  ArtistCircle(id: t.$3, name: t.$3),
              ],
            ),
            const SectionTitle('Álbuns'),
            HorizontalShelf(
              children: [
                for (final t in _tracks.skip(2))
                  AlbumTile(id: t.$4, title: t.$4),
              ],
            ),
            const SectionTitle('Progresso'),
            const ProgressBarThin(value: 0.35),
            const SizedBox(height: 12),
            const ProgressBarThin(
              value: 0.6,
              height: BergaSizes.progressHeightLarge,
            ),
            const SectionTitle('Avisos'),
            const OfflineBanner(
              message:
                  'Servidor indisponível. Mostrando suas músicas baixadas.',
            ),
            const SizedBox(height: 8),
            OfflineBanner(
              message: 'Sessão expirada. Entre para buscar no servidor.',
              actionLabel: 'Entrar',
              onAction: () => AppToast.show(context, 'Entrar'),
            ),
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Servidor',
                    style: BergaText.trackTitle.copyWith(color: c.tx),
                  ),
                  Text('https://musica.meuservidor.com', style: mu),
                  Text(
                    'Conectado como Você',
                    style: BergaText.secondary.copyWith(color: c.gr),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerLeft,
              child: PrimaryButton(
                label: 'Mostrar aviso rápido',
                onPressed: () =>
                    AppToast.show(context, 'Na fila: toca depois da atual'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chips(List<Widget> chips) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Wrap(spacing: BergaSizes.chipGap, runSpacing: 8, children: chips),
    );
  }

  Widget _swatch(BuildContext context, String name, Color color) {
    final c = BergaColors.of(context);
    return Column(
      children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(BergaSizes.coverRadius),
            border: Border.all(color: c.mu.withValues(alpha: 0.4)),
          ),
        ),
        const SizedBox(height: 4),
        Text(name, style: BergaText.secondary.copyWith(color: c.mu)),
      ],
    );
  }

  Widget _row(
    BuildContext context,
    int index, {
    bool playing = false,
    String? addedBy,
    DownloadState downloadState = DownloadState.naoBaixada,
    double? progress,
  }) {
    final t = _tracks[index];
    return TrackRow(
      id: t.$1,
      title: t.$2,
      artist: t.$3,
      addedBy: addedBy,
      playing: playing,
      downloadState: downloadState,
      downloadProgress: progress,
      onTap: () => AppToast.show(context, 'Tocando ${t.$2}'),
      onMore: () => TrackActionsSheet.show(
        context,
        TrackActionsSheet(
          id: t.$1,
          title: t.$2,
          artist: t.$3,
          onAddToQueue: () =>
              AppToast.show(context, 'Na fila: toca depois da atual'),
          disabledMessage: 'Disponível a partir dos próximos passos',
        ),
      ),
    );
  }
}
