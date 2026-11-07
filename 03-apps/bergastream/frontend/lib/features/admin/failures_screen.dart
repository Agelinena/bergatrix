import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/routes.dart';
import '../../core/network/api_error.dart';
import '../../core/platform/app_layout.dart';
import '../../core/theme/berga_colors.dart';
import '../../core/theme/berga_sizes.dart';
import '../../core/theme/berga_text.dart';
import '../../core/utils/format.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/search_result.dart';
import '../../data/repositories/failures_repository.dart';
import '../player/player_texts.dart';

/// Lista da aba (abertas ou ignoradas).
final failuresProvider = FutureProvider.autoDispose
    .family<List<DownloadFailure>, bool>(
      (ref, ignored) =>
          ref.read(failuresRepositoryProvider).list(ignored: ignored),
    );

/// "Músicas com erro" (só admin): as que nenhuma fonte conseguiu baixar.
/// Tentar de novo, escolher a versão à mão (YouTube Music ou Deezer) ou
/// ignorar. As que estão em playlists aparecem primeiro.
class FailuresScreen extends ConsumerStatefulWidget {
  const FailuresScreen({super.key});

  @override
  ConsumerState<FailuresScreen> createState() => _FailuresScreenState();
}

class _FailuresScreenState extends ConsumerState<FailuresScreen> {
  bool _ignored = false;

  @override
  Widget build(BuildContext context) {
    final c = BergaColors.of(context);
    final mu = BergaText.secondary.copyWith(color: c.mu);
    final async = ref.watch(failuresProvider(_ignored));
    final items = async.value;
    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          color: c.gr,
          onRefresh: () => ref.refresh(failuresProvider(_ignored).future),
          child: ListView(
            padding: AppLayout.screenPadding(context),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: GestureDetector(
                  onTap: () => context.canPop()
                      ? context.pop()
                      : context.go(AppRoutes.settings),
                  child: Text('‹ Ajustes', style: mu),
                ),
              ),
              const SizedBox(height: 10),
              const ScreenTitle('Músicas com erro', bottom: 4),
              Text(
                'Músicas que o servidor não conseguiu baixar (Deezer e '
                'YouTube). As que estão em playlists vêm primeiro.',
                style: mu,
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: BergaSizes.chipGap,
                children: [
                  AppChip(
                    label: 'Abertas',
                    active: !_ignored,
                    onTap: () => setState(() => _ignored = false),
                  ),
                  AppChip(
                    label: 'Ignoradas',
                    active: _ignored,
                    onTap: () => setState(() => _ignored = true),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (async.hasError && items == null)
                Text(
                  async.error is ApiException
                      ? (async.error! as ApiException).serverMessage
                      : 'Não foi possível carregar a lista.',
                  style: mu,
                ),
              if (items == null && !async.hasError)
                Text('Carregando…', style: mu),
              if (items != null && items.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    _ignored
                        ? 'Nenhuma música ignorada.'
                        : 'Nenhuma música com erro. Tudo baixado!',
                    style: mu,
                  ),
                ),
              for (final f in items ?? const <DownloadFailure>[])
                _FailureRow(failure: f, ignoredList: _ignored),
            ],
          ),
        ),
      ),
    );
  }
}

/// Faz a ação, mostra o resultado e recarrega as duas listas.
Future<void> _run(
  BuildContext context,
  WidgetRef ref,
  Future<void> Function() action,
  String done,
) async {
  try {
    await action();
    ref
      ..invalidate(failuresProvider(false))
      ..invalidate(failuresProvider(true));
    if (context.mounted) AppToast.show(context, done);
  } on ApiException catch (e) {
    if (context.mounted) AppToast.show(context, e.serverMessage);
  }
}

class _FailureRow extends ConsumerWidget {
  const _FailureRow({required this.failure, required this.ignoredList});

  final DownloadFailure failure;
  final bool ignoredList;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = BergaColors.of(context);
    final mu = BergaText.secondary.copyWith(color: c.mu);
    final f = failure;
    final info = [
      if (f.queued) 'na fila de novo',
      if (f.playlists > 0)
        f.playlists == 1 ? 'em 1 playlist' : 'em ${f.playlists} playlists',
      f.attempts == 1 ? '1 tentativa' : '${f.attempts} tentativas',
    ];
    return InkWell(
      onTap: () => _actions(context, ref),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          spacing: 12,
          children: [
            Cover(
              seed: f.trackId,
              title: f.title,
              size: 48,
              image: imageFor(f.coverUrl),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    f.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: BergaText.trackTitle.copyWith(color: c.tx),
                  ),
                  Text(
                    '${f.artist}'
                    '${f.durationSeconds > 0 ? ' · ${formatDuration(f.durationSeconds)}' : ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: mu,
                  ),
                  if (f.error case final error?)
                    Text(
                      error,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: mu.copyWith(color: c.ac),
                    ),
                  Text(info.join(' · '), style: mu.copyWith(color: c.gr)),
                ],
              ),
            ),
            Icon(Icons.more_vert, color: c.mu),
          ],
        ),
      ),
    );
  }

  Future<void> _actions(BuildContext context, WidgetRef ref) async {
    final c = BergaColors.of(context);
    final repo = ref.read(failuresRepositoryProvider);
    final action = await showModalBottomSheet<Future<void> Function()>(
      context: context,
      useRootNavigator: true,
      backgroundColor: c.card,
      barrierColor: c.scrim,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(BergaSizes.sheetRadius),
        ),
      ),
      builder: (sheet) {
        Widget item(IconData icon, String label, Future<void> Function() run) =>
            ListTile(
              leading: Icon(icon, color: c.tx),
              title: Text(label, style: BergaText.body.copyWith(color: c.tx)),
              onTap: () => Navigator.of(sheet).pop(run),
            );
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                child: Text(
                  '${failure.title} · ${failure.artist}',
                  maxLines: 2,
                  style: BergaText.trackTitle.copyWith(color: c.tx),
                ),
              ),
              item(
                Icons.manage_search,
                'Procurar manualmente',
                () => _search(context, ref),
              ),
              item(
                Icons.refresh,
                'Tentar de novo',
                () => _run(
                  context,
                  ref,
                  () => repo.retry(failure.trackId),
                  'Na fila de novo',
                ),
              ),
              item(
                ignoredList ? Icons.undo : Icons.visibility_off_outlined,
                ignoredList ? 'Voltar para a lista' : 'Ignorar',
                () => _run(
                  context,
                  ref,
                  () => repo.setIgnored(failure.trackId, !ignoredList),
                  ignoredList ? 'De volta à lista' : 'Ignorada',
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
    await action?.call();
  }

  Future<void> _search(BuildContext context, WidgetRef ref) async {
    final source = await showDialog<SearchResult>(
      context: context,
      barrierColor: BergaColors.of(context).scrim,
      builder: (_) => _SourcePicker(failure: failure),
    );
    if (source == null || !context.mounted) return;
    await _run(
      context,
      ref,
      () => ref
          .read(failuresRepositoryProvider)
          .chooseSource(failure.trackId, source),
      'Baixando a versão escolhida',
    );
  }
}

/// Busca as versões da música e deixa escolher uma (duração mais parecida
/// primeiro). Dá para mudar o texto da busca.
class _SourcePicker extends ConsumerStatefulWidget {
  const _SourcePicker({required this.failure});

  final DownloadFailure failure;

  @override
  ConsumerState<_SourcePicker> createState() => _SourcePickerState();
}

class _SourcePickerState extends ConsumerState<_SourcePicker> {
  late final _query = TextEditingController(
    text: '${widget.failure.artist.split(',').first} ${widget.failure.title}',
  );
  Future<List<SearchResult>>? _results;

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _search() => setState(() {
    _results = ref
        .read(failuresRepositoryProvider)
        .candidates(widget.failure.trackId, query: _query.text.trim());
  });

  @override
  Widget build(BuildContext context) {
    final c = BergaColors.of(context);
    final mu = BergaText.secondary.copyWith(color: c.mu);
    final want = widget.failure.durationSeconds;
    return Dialog(
      backgroundColor: c.card,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(BergaSizes.cardRadius),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 620),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 10,
            children: [
              Text(
                'Escolher a versão',
                style: BergaText.trackTitle.copyWith(color: c.tx),
              ),
              Text(
                'Original: ${widget.failure.title} · ${widget.failure.artist}'
                '${want > 0 ? ' · ${formatDuration(want)}' : ''}',
                style: mu,
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: c.mu.withValues(alpha: 0.4)),
                  borderRadius: BorderRadius.circular(BergaSizes.fieldRadius),
                ),
                child: AppTextField(
                  hint: 'Artista e música',
                  controller: _query,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _search(),
                  suffix: IconButton(
                    tooltip: 'Buscar',
                    icon: const Icon(Icons.search, size: 20),
                    onPressed: _search,
                  ),
                ),
              ),
              Flexible(
                child: FutureBuilder<List<SearchResult>>(
                  future: _results,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return Text('Buscando…', style: mu);
                    }
                    if (snapshot.hasError) {
                      final e = snapshot.error;
                      return Text(
                        e is ApiException
                            ? e.serverMessage
                            : 'A busca não respondeu.',
                        style: mu,
                      );
                    }
                    final results = snapshot.data ?? const [];
                    if (results.isEmpty) {
                      return Text('Nada encontrado. Mude a busca.', style: mu);
                    }
                    return ListView(
                      shrinkWrap: true,
                      children: [
                        for (final r in results)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Cover(
                              seed: r.externalId,
                              title: r.title,
                              size: 40,
                              image: imageFor(r.coverUrl),
                            ),
                            title: Text(
                              r.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: BergaText.body.copyWith(color: c.tx),
                            ),
                            subtitle: Text(
                              [
                                r.artist,
                                if (r.durationSeconds > 0)
                                  formatDuration(r.durationSeconds),
                                r.provider == 'deezer'
                                    ? 'Deezer'
                                    : 'YouTube Music',
                              ].join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: _closeEnough(r, want)
                                  ? mu.copyWith(color: c.gr)
                                  : mu,
                            ),
                            onTap: () => Navigator.of(context).pop(r),
                          ),
                      ],
                    );
                  },
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: AppChip(
                  label: 'Cancelar',
                  onTap: () => Navigator.of(context).pop(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Duração a até 3 s da original (destacada em verde).
  static bool _closeEnough(SearchResult r, int want) =>
      want > 0 && (r.durationSeconds - want).abs() <= 3;
}
