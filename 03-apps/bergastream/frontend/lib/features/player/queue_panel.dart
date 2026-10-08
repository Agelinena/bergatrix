import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/player/player_texts.dart';

import '../../core/theme/berga_colors.dart';
import '../../core/theme/berga_sizes.dart';
import '../../core/theme/berga_text.dart';
import '../../core/widgets/widgets.dart';
import 'play_queue.dart';
import 'player_controller.dart';

/// Painel da fila (Seção 6.6, item 6): "Sua fila" e "A seguir", com
/// reordenar (arrastar pela alça) e remover.
class QueuePanel extends ConsumerStatefulWidget {
  const QueuePanel({super.key});

  /// Quantas faixas de "a seguir" aparecem antes de "Ver todas".
  static const preview = 4;

  @override
  ConsumerState<QueuePanel> createState() => _QueuePanelState();
}

class _QueuePanelState extends ConsumerState<QueuePanel> {
  bool _showAll = false;

  @override
  Widget build(BuildContext context) {
    final c = BergaColors.of(context);
    final state = ref.watch(playerProvider);
    final controller = ref.read(playerProvider.notifier);
    final mu = BergaText.secondary.copyWith(color: c.mu);
    final upNext = _showAll
        ? state.upNext
        : state.upNext.take(QueuePanel.preview).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Header(
          // Na sessão a fila é de todos (mesma regra: toca depois da atual).
          title: state.shared ? 'Fila da sessão' : 'Sua fila',
          action: state.manual.isEmpty
              ? null
              : AppChip(label: 'Limpar fila', onTap: controller.clearQueue),
        ),
        if (state.manual.isEmpty)
          Text(
            state.shared
                ? 'Vazia. Use "Adicionar à fila" e a música toca logo depois '
                      'da atual, para todos.'
                : 'Vazia. Use "Adicionar à fila" e a música toca logo depois '
                      'da atual.',
            style: mu,
          )
        else
          _ReorderableItems(
            items: state.manual,
            onReorder: controller.reorderQueue,
            onRemove: controller.removeFromQueue,
          ),
        _Header(
          title:
              state.shared ||
                  state.context == 'Busca' ||
                  state.context == 'Sua fila'
              ? 'A seguir'
              : 'A seguir da playlist',
        ),
        if (state.upNext.isEmpty)
          Text('Nada a seguir.', style: mu)
        else ...[
          _ReorderableItems(
            items: upNext,
            onReorder: controller.reorderUpNext,
            onRemove: controller.removeFromQueue,
          ),
          if (state.upNext.length > QueuePanel.preview)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: AppChip(
                label: _showAll
                    ? 'Ver menos'
                    : 'Ver todas (${state.upNext.length})',
                onTap: () => setState(() => _showAll = !_showAll),
              ),
            ),
        ],
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.title, this.action});

  final String title;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(
        top: BergaSizes.h2Top,
        bottom: BergaSizes.h2Bottom,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: BergaText.h2.copyWith(color: BergaColors.of(context).tx),
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}

class _ReorderableItems extends StatelessWidget {
  const _ReorderableItems({
    required this.items,
    required this.onReorder,
    required this.onRemove,
  });

  final List<QueueItem> items;
  final void Function(int oldIndex, int newIndex) onReorder;
  final void Function(int uid) onRemove;

  @override
  Widget build(BuildContext context) {
    return ReorderableListView(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      onReorderItem: onReorder,
      children: [
        for (final (index, item) in items.indexed)
          _QueueRow(
            key: ValueKey(item.uid),
            index: index,
            item: item,
            onRemove: () => onRemove(item.uid),
          ),
      ],
    );
  }
}

class _QueueRow extends StatelessWidget {
  const _QueueRow({
    super.key,
    required this.index,
    required this.item,
    required this.onRemove,
  });

  final int index;
  final QueueItem item;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final c = BergaColors.of(context);
    final track = item.track;
    return ColoredBox(
      color: c.bg,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          vertical: BergaSizes.trackPaddingVertical,
        ),
        child: Row(
          spacing: BergaSizes.trackGap,
          children: [
            Cover(
              seed: track.id,
              title: track.title,
              size: BergaSizes.trackCover,
              image: imageFor(track.coverUrl),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: BergaText.trackTitle.copyWith(color: c.tx),
                  ),
                  Text(
                    track.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: BergaText.secondary.copyWith(color: c.mu),
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: onRemove,
              icon: const Icon(Icons.close),
              iconSize: 20,
              color: c.mu,
              tooltip: 'Remover da fila',
            ),
            ReorderableDragStartListener(
              index: index,
              child: Icon(Icons.drag_handle, color: c.mu),
            ),
          ],
        ),
      ),
    );
  }
}
