/// Wraps a track row with mobile-only swipe gestures:
///   - swipe RIGHT  →  add to queue          (when [enableEnqueue] is true)
///   - swipe LEFT   →  remove from queue     (when [enableDequeue] is true)
///
/// We use [Dismissible] under the hood, but always return `false` from
/// `confirmDismiss` so the row stays mounted — the gesture just fires
/// the action and snaps back.
///
/// On screens wider than [kDesktopBreakpoint] the wrapper becomes a
/// no-op (returns [child] directly), so desktop users keep their
/// horizontal-scroll / drag affordances intact.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants.dart';
import '../core/theme/app_theme.dart';
import '../models/track.dart';
import '../providers/player_provider.dart';

class SwipeTrackActions extends ConsumerWidget {
  final Track track;
  final Widget child;
  final bool enableEnqueue;
  final bool enableDequeue;

  /// Optional override for the dismissible key suffix.  Some lists
  /// render the same track multiple times (queue, history) — the
  /// caller must disambiguate so the Dismissible widget can be
  /// uniquely identified by Flutter's element tree.
  final String? keySuffix;

  const SwipeTrackActions({
    super.key,
    required this.track,
    required this.child,
    this.enableEnqueue = false,
    this.enableDequeue = false,
    this.keySuffix,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isMobile = MediaQuery.of(context).size.width < kDesktopBreakpoint;
    if (!isMobile || (!enableEnqueue && !enableDequeue)) return child;

    final direction = enableEnqueue && enableDequeue
        ? DismissDirection.horizontal
        : enableEnqueue
            ? DismissDirection.startToEnd
            : DismissDirection.endToStart;

    return Dismissible(
      key: Key('swipe_${track.id}_${keySuffix ?? ''}'),
      direction: direction,
      // 25% threshold — a deliberate gesture, not a stray scroll.
      dismissThresholds: const {
        DismissDirection.startToEnd: 0.25,
        DismissDirection.endToStart: 0.25,
      },
      background: enableEnqueue
          ? Container(
              color: AppColors.primary.withValues(alpha: 0.85),
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: const Row(
                children: [
                  Icon(Icons.queue_music, color: Colors.black, size: 22),
                  SizedBox(width: 8),
                  Text(
                    'Adicionar à fila',
                    style: TextStyle(
                      color: Colors.black,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            )
          : const SizedBox.shrink(),
      secondaryBackground: enableDequeue
          ? Container(
              color: Colors.redAccent.withValues(alpha: 0.85),
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(
                    'Tirar da fila',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  SizedBox(width: 8),
                  Icon(Icons.playlist_remove, color: Colors.white, size: 22),
                ],
              ),
            )
          : const SizedBox.shrink(),
      confirmDismiss: (dir) async {
        if (dir == DismissDirection.startToEnd && enableEnqueue) {
          _handleEnqueue(context, ref);
        } else if (dir == DismissDirection.endToStart && enableDequeue) {
          _handleDequeue(context, ref);
        }
        // Never actually dismiss — the row stays mounted.
        return false;
      },
      child: child,
    );
  }

  void _handleEnqueue(BuildContext context, WidgetRef ref) {
    ref.read(playerProvider.notifier).insertNextInQueue(track);
    _toast(context, 'Adicionada à fila: ${track.title}');
  }

  void _handleDequeue(BuildContext context, WidgetRef ref) {
    final removed =
        ref.read(playerProvider.notifier).removeFromQueueById(track.id);
    if (removed) {
      _toast(context, 'Removida da fila: ${track.title}');
    } else {
      _toast(context, 'Essa música não está na fila');
    }
  }

  void _toast(BuildContext context, String msg) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(
      SnackBar(
        content: Text(msg, maxLines: 1, overflow: TextOverflow.ellipsis),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
