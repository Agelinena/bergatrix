import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../app/catalog_navigation.dart';
import '../../app/routes.dart';
import '../../core/network/api_error.dart';
import '../../core/platform/app_layout.dart';
import '../../core/theme/berga_colors.dart';
import '../../core/theme/berga_sizes.dart';
import '../../core/theme/berga_text.dart';
import '../../core/utils/format.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/playlist_models.dart';
import '../../data/models/playlist_op.dart';
import '../../data/repositories/playlist_repository.dart';
import '../auth/session.dart';
import '../downloads/download_manager.dart';
import '../sync/sync_service.dart';
import '../downloads/playlist_download_button.dart';
import '../player/player_controller.dart';
import '../player/player_texts.dart';
import '../player/track_menu.dart';
import '../playlists/playlist_store.dart';
import 'library_providers.dart';

/// Detalhe da playlist (Seção 6.4).
/// Aviso das ações que dependem do servidor, quando offline.
const offlineMessage = 'Indisponível sem servidor';

class PlaylistScreen extends ConsumerStatefulWidget {
  const PlaylistScreen({super.key, required this.id});

  final String id;

  @override
  ConsumerState<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends ConsumerState<PlaylistScreen> {
  String _query = '';
  bool _shuffle = false;
  bool _reordering = false;

  /// Ordem enquanto reordena (ids), aplicada ao salvar.
  List<PlaylistTrack>? _draft;

  PlaylistRepository get _repo => ref.read(playlistRepositoryProvider);
  PlaylistEditor get _editor => ref.read(playlistEditorProvider);

  void _refresh() {
    ref.invalidate(serverPlaylistDetailProvider);
    ref.invalidate(serverPlaylistsProvider);
  }

  Future<void> _run(Future<void> Function() action, {String? done}) async {
    try {
      await action();
      if (done != null && mounted) AppToast.show(context, done);
    } on ApiException catch (e) {
      if (mounted) AppToast.show(context, e.message);
    } on PlaylistConflict catch (e) {
      if (mounted) AppToast.show(context, e.message);
    }
  }

  bool get _online => ref.read(sessionProvider).canUseServer;

  /// Ações que só existem no servidor (foto, pessoas, compartilhar).
  void _needsServer(VoidCallback action) =>
      _online ? action() : AppToast.show(context, offlineMessage);

  void _play(PlaylistDetail p, List<PlaylistTrack> shown, {int index = 0}) {
    if (shown.isEmpty) return;
    final player = ref.read(playerProvider.notifier);
    // Aleatório ligado toca embaralhado; desligado, na ordem da lista.
    if (ref.read(playerProvider).shuffle != _shuffle) player.toggleShuffle();
    player.playList(
      [for (final t in shown) t.asResult],
      index,
      context: p.name,
      playlistId: p.id,
    );
  }

  Future<void> _share(PlaylistDetail p) async {
    final server = ref.read(sessionProvider).server ?? '';
    await shareText(
      context,
      ref,
      '$server/#${AppRoutes.playlist(p.id)}',
      copiedMessage: 'Link da playlist copiado',
    );
  }

  Future<void> _changePhoto() async {
    final file = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1200,
      imageQuality: 85,
    );
    if (file == null) return;
    final bytes = await file.readAsBytes();
    final mime =
        file.mimeType ??
        (file.name.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg');
    await _run(() async {
      await _repo.uploadCover(
        widget.id,
        bytes,
        filename: file.name,
        mimeType: mime,
      );
      _refresh();
    }, done: 'Foto da playlist trocada');
  }

  Future<void> _rename(PlaylistDetail p) async {
    final name = await showTextInputDialog(
      context,
      title: 'Renomear playlist',
      hint: 'Nome da playlist',
      initial: p.name,
    );
    if (name != null) {
      await _run(() => _editor.rename(p.id, name: name, current: p.name));
    }
  }

  Future<void> _delete(PlaylistDetail p) async {
    final choice = await showChoiceDialog(
      context,
      message:
          'Apagar "${p.name}"? As músicas continuam disponíveis em outras '
          'playlists.',
      options: const ['Cancelar', 'Apagar'],
    );
    if (choice != 1 || !mounted) return;
    try {
      // Com a versão que a pessoa estava vendo: se mudou em outro lugar
      // nesse meio-tempo, o servidor não apaga e pergunta (aviso).
      await _editor.delete(p.id, updatedAt: p.updatedAt);
      if (mounted) {
        AppToast.show(
          context,
          _online
              ? 'Playlist apagada'
              : 'Playlist apagada. O servidor será avisado quando voltar.',
        );
        context.pop();
      }
    } on ApiException catch (e) {
      if (mounted) AppToast.show(context, e.message);
    } on PlaylistConflict catch (e) {
      if (mounted) AppToast.show(context, e.message);
    }
  }

  Future<void> _saveOrder(PlaylistDetail p) async {
    final draft = _draft;
    setState(() {
      _reordering = false;
      _draft = null;
    });
    if (draft == null) return;
    await _run(
      () => _editor.reorder(
        p.id,
        [
          for (final t in sortAndFilter(p.tracks, PlaylistSort.playlist, ''))
            t.trackId,
        ],
        [for (final t in draft) t.trackId],
      ),
    );
  }

  /// "Ordenar por": critério e sentido; a escolha fica para esta playlist.
  Future<void> _chooseSort(PlaylistSort current) async {
    final c = BergaColors.of(context);
    final chosen = await showModalBottomSheet<PlaylistSort>(
      context: context,
      useRootNavigator: true,
      backgroundColor: c.card,
      barrierColor: c.scrim,
      elevation: 0,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(BergaSizes.sheetRadius),
        ),
      ),
      builder: (sheetContext) => SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.8,
          ),
          child: ListView(
            shrinkWrap: true,
            padding: BergaSizes.sheetPadding,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'Ordenar por',
                  style: BergaText.h2.copyWith(color: c.tx),
                ),
              ),
              for (final option in PlaylistSort.values)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => Navigator.of(sheetContext).pop(option),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            option.label,
                            style: BergaText.body.copyWith(
                              color: option == current ? c.gr : c.tx,
                            ),
                          ),
                        ),
                        if (option == current)
                          Icon(Icons.check, size: 20, color: c.gr),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (chosen != null) {
      ref.read(playlistSortProvider(widget.id).notifier).set(chosen);
    }
  }

  void _openMenu(PlaylistDetail p) {
    final role = p.playlistRole;
    TrackActionsSheet.show(
      context,
      TrackActionsSheet(
        id: p.id,
        title: p.name,
        artist: playlistSubtitle(
          tracks: p.tracks.length,
          people: 1 + p.members.length,
        ),
        onShare: () => _share(p),
        // A folha é de faixa; aqui só as ações extras da playlist importam.
        extraActions: [
          if (role.canEdit) ('Renomear', () => _rename(p)),
          if (role.canEdit) ('Trocar foto', () => _needsServer(_changePhoto)),
          if (role.canEdit && p.tracks.length > 1)
            (
              'Reordenar',
              () => setState(() {
                _reordering = true;
                // Arrastar só faz sentido na ordem da playlist.
                ref
                    .read(playlistSortProvider(widget.id).notifier)
                    .set(PlaylistSort.playlist);
                _draft = sortAndFilter(p.tracks, PlaylistSort.playlist, '');
              }),
            ),
          if (role.isOwner && !PlaylistOp.isRef(p.id))
            (
              'Pessoas',
              () => _needsServer(
                () => context.push(AppRoutes.playlistPeople(p.id)),
              ),
            ),
          if (role.isOwner) ('Apagar playlist', () => _delete(p)),
        ],
        disabledMessage: 'Indisponível',
      ),
      hideTrackActions: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = BergaColors.of(context);
    final mu = BergaText.secondary.copyWith(color: c.mu);
    // Servidor (ou, sem ele, a última cópia / a playlist baixada) com as
    // alterações ainda não enviadas.
    final online = ref.watch(sessionProvider.select((s) => s.canUseServer));
    final AsyncValue<PlaylistDetail?> detail = ref.watch(
      playlistDetailProvider(widget.id),
    );
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: AppLayout.screenPadding(context),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: GestureDetector(
                onTap: () => context.canPop()
                    ? context.pop()
                    : context.go(AppRoutes.library),
                child: Text('‹ Biblioteca', style: mu),
              ),
            ),
            ...detail.when(
              loading: () => [
                Padding(
                  padding: const EdgeInsets.only(top: 20),
                  child: Text('Carregando…', style: mu),
                ),
              ],
              error: (e, _) => [
                Padding(
                  padding: const EdgeInsets.only(top: 20, bottom: 12),
                  child: Text(
                    e is PlaylistUnavailable
                        ? 'Indisponível offline. Abra a playlist com servidor '
                              'uma vez (ou baixe-a) para ver e editar sem ele.'
                        : e is ApiException && e.statusCode == 404
                        ? 'Playlist não encontrada ou sem acesso.'
                        : e is ApiException
                        ? e.message
                        : 'Não foi possível abrir a playlist.',
                    style: mu,
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: AppChip(label: 'Tentar de novo', onTap: _refresh),
                ),
              ],
              data: (p) => p == null
                  ? [
                      Padding(
                        padding: const EdgeInsets.only(top: 20),
                        child: Text(
                          'Indisponível offline. Baixe a playlist para ouvir '
                          'sem servidor.',
                          style: mu,
                        ),
                      ),
                    ]
                  : _content(context, p, online: online),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _content(
    BuildContext context,
    PlaylistDetail p, {
    required bool online,
  }) {
    final c = BergaColors.of(context);
    final mu = BergaText.secondary.copyWith(color: c.mu);
    final me = ref.watch(sessionProvider.select((s) => s.username));
    // Edita também offline: as alterações vão na volta do servidor.
    final role = p.playlistRole;
    final sort = ref.watch(playlistSortProvider(widget.id));
    final synced = !PlaylistOp.isRef(p.id);
    final pendingIds = ref.watch(pendingPlaylistIdsProvider);
    final hasPending =
        pendingIds.contains(p.id) || pendingIds.contains(widget.id);
    final states = ref.watch(trackDownloadStatesProvider).value ?? const {};
    String who(Person? person) => person == null
        ? '?'
        : person.username == me
        ? 'Você'
        : person.name;
    final people = [who(p.owner), for (final m in p.members) who(m.user)];
    final shown = _reordering ? _draft! : sortAndFilter(p.tracks, sort, _query);
    final playingId = ref.watch(
      playerProvider.select((s) => s.current?.track.id),
    );

    return [
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: LayoutBuilder(
          builder: (context, constraints) => GestureDetector(
            onTap: role.canEdit && synced
                ? () => _needsServer(_changePhoto)
                : null,
            // Capa baixada (file://) ou do servidor.
            child: Cover.playlist(
              size: constraints.maxWidth.clamp(
                0,
                BergaSizes.playlistCoverMaxHeight,
              ),
              initialSize: 60,
              image: serverImage(ref, p.coverUrl),
            ),
          ),
        ),
      ),
      ScreenTitle(p.name, bottom: 4),
      if (p.description.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            p.description,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: mu,
          ),
        ),
      Text(
        [
          '${p.tracks.length} músicas',
          totalDuration(p.tracks.map((t) => t.durationSeconds)),
          if (people.length > 1) 'colaboram: ${people.join(', ')}',
        ].join(' · '),
        style: mu,
      ),
      if (hasPending)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            spacing: 6,
            children: [
              Icon(Icons.cloud_upload_outlined, size: 16, color: c.mu),
              Expanded(
                child: Text(
                  online
                      ? 'Enviando alterações…'
                      : 'Alterações salvas no aparelho. Vão para o servidor '
                            'quando ele voltar.',
                  style: mu,
                ),
              ),
            ],
          ),
        ),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Wrap(
          spacing: 10,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            PlayButton(playing: false, onPressed: () => _play(p, shown)),
            AppChip(
              label: 'Aleatório',
              icon: Icons.shuffle,
              active: _shuffle,
              onTap: () => setState(() => _shuffle = !_shuffle),
            ),
            AppChip(
              label: 'Compartilhar',
              onTap: online && synced
                  ? () => _share(p)
                  : () => AppToast.show(context, offlineMessage),
            ),
            if (online && synced && !hasPending)
              PlaylistDownloadButton(playlist: p),
            if (online && synced && !hasPending) _ChangesBadge(playlist: p),
            if (online || role.canEdit)
              IconButton(
                onPressed: () => _openMenu(p),
                icon: const Icon(Icons.more_vert),
                color: c.mu,
                tooltip: 'Opções da playlist',
              ),
          ],
        ),
      ),
      if (_reordering)
        Row(
          children: [
            Expanded(
              child: Text('Arraste pela alça para mudar a ordem.', style: mu),
            ),
            AppChip(
              label: 'Concluir',
              active: true,
              onTap: () => _saveOrder(p),
            ),
          ],
        )
      else
        Row(
          spacing: 10,
          children: [
            Expanded(
              child: AppTextField(
                hint: 'Buscar na playlist',
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            AppChip(
              label: sort.short,
              icon: Icons.sort,
              onTap: () => _chooseSort(sort),
            ),
          ],
        ),
      const SizedBox(height: 10),
      if (p.tracks.isEmpty)
        Text(
          role.canEdit
              ? 'Playlist vazia. Use "Adicionar à playlist" na Busca.'
              : 'Playlist vazia.',
          style: mu,
        ),
      if (_reordering)
        ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          onReorderItem: (from, to) => setState(() {
            _draft!.insert(to, _draft!.removeAt(from));
          }),
          children: [
            for (final (i, t) in shown.indexed)
              Row(
                key: ValueKey(t.trackId),
                children: [
                  Expanded(
                    child: TrackRow(
                      id: t.trackId,
                      title: t.title,
                      artist: t.artist,
                      cover: imageFor(t.coverUrl),
                    ),
                  ),
                  ReorderableDragStartListener(
                    index: i,
                    child: Icon(Icons.drag_handle, color: c.mu),
                  ),
                ],
              ),
          ],
        )
      else
        for (final (i, t) in shown.indexed)
          TrackRow(
            key: ValueKey(t.trackId),
            id: t.trackId,
            title: t.title,
            artist: t.artist,
            addedBy: t.addedBy == null ? null : who(t.addedBy),
            cover: imageFor(t.coverUrl),
            playing: playingId == t.asResult.id,
            downloadState: states[t.asResult.id] ?? DownloadState.naoBaixada,
            onTap: () => _play(p, shown, index: i),
            onMore: () => showTrackMenu(
              context,
              ref,
              t.asResult,
              onGoToAlbum: goToAlbumOf(context, t.asResult),
              onGoToArtist: goToArtistOf(context, t.asResult),
              extraActions: [
                if (role.canEdit)
                  (
                    'Remover desta playlist',
                    () => _run(
                      () => _editor.removeTrack(p.id, t.trackId),
                      done: 'Removida de ${p.name}',
                    ),
                  ),
              ],
            ),
            onQueue: () => queueTrack(context, ref, t.asResult),
          ),
      if (shown.isEmpty && _query.isNotEmpty)
        Text('Nada encontrado para "$_query".', style: mu),
    ];
  }
}

/// Selo "N novas músicas" quando a playlist baixada mudou no servidor
/// (Seção 8.4); tocar atualiza o download.
class _ChangesBadge extends ConsumerWidget {
  const _ChangesBadge({required this.playlist});

  final PlaylistDetail playlist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final changes =
        ref.watch(playlistChangesProvider(playlist.id)).value ??
        PlaylistChanges.none;
    if (changes.isEmpty) return const SizedBox.shrink();
    final c = BergaColors.of(context);
    final label = changes.added > 0
        ? (changes.added == 1
              ? '1 nova música'
              : '${changes.added} novas músicas')
        : (changes.removed == 1
              ? '1 música removida'
              : '${changes.removed} músicas removidas');
    return AppChip(
      label: label,
      icon: Icons.sync,
      iconColor: c.gr,
      onTap: () =>
          ref.read(downloadManagerProvider.notifier).downloadPlaylist(playlist),
    );
  }
}
