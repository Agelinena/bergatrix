import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/router.dart';
import '../../core/network/api_error.dart';
import '../../core/theme/berga_colors.dart';
import '../../core/theme/berga_sizes.dart';
import '../../core/theme/berga_text.dart';
import '../../core/widgets/widgets.dart';
import 'playlist_store.dart';

/// Faixa da Biblioteca quando a sincronização precisa de uma decisão.
class SyncNoticesBanner extends ConsumerWidget {
  const SyncNoticesBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notices = ref.watch(syncNoticesProvider).value ?? const [];
    if (notices.isEmpty) return const SizedBox.shrink();
    final c = BergaColors.of(context);
    final n = notices.length;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => showSyncNotices(context),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: c.card,
            borderRadius: BorderRadius.circular(BergaSizes.cardRadius),
            border: Border.all(color: c.ac),
          ),
          child: Row(
            spacing: 10,
            children: [
              Icon(Icons.sync_problem, color: c.ac),
              Expanded(
                child: Text(
                  n == 1
                      ? '1 alteração de playlist precisa da sua decisão'
                      : '$n alterações de playlist precisam da sua decisão',
                  style: BergaText.trackTitle.copyWith(color: c.tx),
                ),
              ),
              Icon(Icons.chevron_right, color: c.mu),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> showSyncNotices(BuildContext context) {
  final c = BergaColors.of(context);
  return showModalBottomSheet<void>(
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
    builder: (_) => const _NoticesSheet(),
  );
}

class _NoticesSheet extends ConsumerWidget {
  const _NoticesSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = BergaColors.of(context);
    final notices = ref.watch(syncNoticesProvider).value ?? const [];
    if (notices.isEmpty) {
      // Tudo decidido: fecha sozinha.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) Navigator.of(context).maybePop();
      });
    }
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.75,
        ),
        child: ListView(
          shrinkWrap: true,
          padding: BergaSizes.sheetPadding,
          children: [
            Text(
              'Sincronização das playlists',
              style: BergaText.h2.copyWith(color: c.tx),
            ),
            const SizedBox(height: 4),
            Text(
              'Estas alterações feitas sem servidor encontraram mudanças '
              'feitas em outro lugar. Nada foi sobrescrito sem você decidir.',
              style: BergaText.secondary.copyWith(color: c.mu),
            ),
            const SizedBox(height: 8),
            for (final n in notices) _NoticeTile(notice: n),
          ],
        ),
      ),
    );
  }
}

/// Texto e opções de cada aviso. A última opção é a principal.
({String text, List<(String, bool mine)> options}) noticeContent(
  SyncNotice n,
) => switch (n.kind) {
  SyncNoticeKind.renameConflict => (
    text:
        'O nome da playlist mudou em outro lugar para "${n.data['theirs']}". '
        'Você tinha renomeado para "${n.data['mine']}".',
    options: [
      ('Manter "${n.data['theirs']}"', false),
      ('Usar "${n.data['mine']}"', true),
    ],
  ),
  SyncNoticeKind.deleteConflict => (
    text:
        '"${n.name}" foi alterada em outro lugar depois que você a apagou, '
        'por isso não foi apagada.',
    options: [('Manter', false), ('Apagar mesmo assim', true)],
  ),
  SyncNoticeKind.gone => (
    text:
        '"${n.name}" foi apagada em outro lugar. '
        '${_lost(n.data['count'] as int? ?? 1, 'aplicada')}',
    options: [('Descartar', false), ('Recriar com minhas mudanças', true)],
  ),
  SyncNoticeKind.forbidden => (
    text:
        'Você não pode mais editar "${n.name}". '
        '${_lost(n.data['count'] as int? ?? 1, 'enviada')}',
    options: [('Entendi', false)],
  ),
};

/// "1 alteração sua não foi aplicada." / "3 alterações suas não foram …".
String _lost(int n, String verb) => n == 1
    ? '1 alteração sua não foi $verb.'
    : '$n alterações suas não foram ${verb}s.';

class _NoticeTile extends ConsumerWidget {
  const _NoticeTile({required this.notice});

  final SyncNotice notice;

  Future<void> _choose(
    BuildContext context,
    WidgetRef ref, {
    required bool mine,
  }) async {
    final editor = ref.read(playlistEditorProvider);
    try {
      if (mine) {
        await editor.applyMine(notice);
      } else {
        await editor.keepServerVersion(notice);
      }
    } on ApiException catch (e) {
      if (context.mounted) AppToast.show(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = BergaColors.of(context);
    final content = noticeContent(notice);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 10,
        children: [
          Text(notice.name, style: BergaText.trackTitle.copyWith(color: c.tx)),
          Text(content.text, style: BergaText.secondary.copyWith(color: c.mu)),
          Wrap(
            spacing: BergaSizes.chipGap,
            runSpacing: 8,
            children: [
              for (final (i, (label, mine)) in content.options.indexed)
                AppChip(
                  label: label,
                  active: i == content.options.length - 1,
                  onTap: () => _choose(context, ref, mine: mine),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Avisa (toast) quando um envio da fila gerou conflitos, em qualquer tela.
class SyncNoticesListener extends ConsumerStatefulWidget {
  const SyncNoticesListener({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<SyncNoticesListener> createState() =>
      _SyncNoticesListenerState();
}

class _SyncNoticesListenerState extends ConsumerState<SyncNoticesListener> {
  StreamSubscription<int>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = ref.read(playlistSyncProvider.notifier).newNotices.listen((n) {
      // Este widget fica acima do Navigator: o aviso usa o overlay do router.
      final overlay = ref
          .read(routerProvider)
          .routerDelegate
          .navigatorKey
          .currentState
          ?.overlay;
      if (overlay == null || !overlay.mounted) return;
      AppToast.show(
        overlay.context,
        n == 1
            ? 'Uma alteração de playlist precisa da sua decisão (Biblioteca)'
            : '$n alterações de playlist precisam da sua decisão (Biblioteca)',
      );
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
