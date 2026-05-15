import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../core/theme/app_theme.dart';
import '../../core/constants.dart';
import '../../providers/player_provider.dart';
import '../../providers/ui_provider.dart';
import '../../screens/player/full_player_screen.dart';
import '../../models/track.dart';
import '../cards/track_card.dart';

class PlayerBar extends ConsumerWidget {
  const PlayerBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    final track = player.currentTrack;
    if (track == null) return const SizedBox.shrink();

    final isDesktop = MediaQuery.of(context).size.width >= kDesktopBreakpoint;

    return Container(
      color: AppColors.surface,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Seek slider com timestamps — cobre toda a largura
          _SeekRow(player: player),
          SizedBox(
            height: kPlayerBarHeight - 28,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: isDesktop
                  ? _DesktopRow(player: player, track: track)
                  : _MobileRow(player: player, track: track),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Desktop: 3 colunas ─────────────────────────────────────────────────────

class _DesktopRow extends ConsumerWidget {
  final PlayerState player;
  final Track track;
  const _DesktopRow({required this.player, required this.track});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nowPlayingVisible = ref.watch(nowPlayingVisibleProvider);

    return Row(
      children: [
        // ── Coluna esquerda: info da faixa ──────────────────────────────
        Expanded(
          flex: 3,
          child: GestureDetector(
            onTap: () => showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              backgroundColor: Colors.transparent,
              builder: (_) => const FullPlayerScreen(),
            ),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: CachedNetworkImage(
                    imageUrl: track.coverUrl ?? '',
                    width: 44, height: 44, fit: BoxFit.cover,
                    errorWidget: (_, __, ___) => Container(
                      width: 44, height: 44, color: AppColors.surfaceVariant,
                      child: const Icon(Icons.music_note),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(track.title,
                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                          overflow: TextOverflow.ellipsis),
                      Text(track.artist,
                          style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
                          overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
                // Botão curtir
                IconButton(
                  icon: const Icon(Icons.favorite_border, size: 18, color: AppColors.textSecondary),
                  tooltip: 'Curtir',
                  onPressed: () {},
                ),
              ],
            ),
          ),
        ),

        // ── Coluna central: controles ───────────────────────────────────
        Expanded(
          flex: 4,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Botões
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    icon: Icon(Icons.shuffle,
                        color: player.shuffle ? AppColors.primary : AppColors.textSecondary,
                        size: 18),
                    onPressed: () => ref.read(playerProvider.notifier).toggleShuffle(),
                    tooltip: 'Aleatório',
                  ),
                  IconButton(
                    icon: const Icon(Icons.skip_previous, size: 26),
                    onPressed: () => ref.read(playerProvider.notifier).previous(),
                  ),
                  _PlayButton(isPlaying: player.isPlaying),
                  IconButton(
                    icon: const Icon(Icons.skip_next, size: 26),
                    onPressed: () => ref.read(playerProvider.notifier).next(),
                  ),
                  IconButton(
                    icon: Icon(
                      player.repeat == RepeatMode.one ? Icons.repeat_one : Icons.repeat,
                      color: player.repeat != RepeatMode.none
                          ? AppColors.primary
                          : AppColors.textSecondary,
                      size: 18,
                    ),
                    onPressed: () => ref.read(playerProvider.notifier).toggleRepeat(),
                    tooltip: 'Repetir',
                  ),
                ],
              ),
            ],
          ),
        ),

        // ── Coluna direita: volume + extras ─────────────────────────────
        Expanded(
          flex: 3,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              // Volume
              const _VolumeControl(),
              // Fila modal
              IconButton(
                icon: const Icon(Icons.queue_music, size: 20, color: AppColors.textSecondary),
                tooltip: 'Ver fila',
                onPressed: () => showModalBottomSheet(
                  context: context,
                  backgroundColor: AppColors.surfaceVariant,
                  isScrollControlled: true,
                  builder: (_) => _QueueSheet(
                    queue: player.queue,
                    currentIndex: player.queueIndex,
                  ),
                ),
              ),
              // Painel "Tocando agora"
              IconButton(
                icon: Icon(
                  Icons.queue_music_outlined,
                  size: 20,
                  color: nowPlayingVisible ? AppColors.primary : AppColors.textSecondary,
                ),
                tooltip: 'Fila / Tocando agora',
                onPressed: () => ref.read(nowPlayingVisibleProvider.notifier).state =
                    !nowPlayingVisible,
              ),
              // Mais opções
              IconButton(
                icon: const Icon(Icons.more_vert, size: 20, color: AppColors.textSecondary),
                tooltip: 'Mais opções',
                onPressed: () => showModalBottomSheet(
                  context: context,
                  backgroundColor: AppColors.surfaceVariant,
                  builder: (_) => TrackMenuSheet(track: track),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ── Mobile: layout compacto ────────────────────────────────────────────────

class _MobileRow extends ConsumerWidget {
  final PlayerState player;
  final Track track;
  const _MobileRow({required this.player, required this.track});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Row(
      children: [
        GestureDetector(
          onTap: () => showModalBottomSheet(
            context: context,
            isScrollControlled: true,
            backgroundColor: Colors.transparent,
            builder: (_) => const FullPlayerScreen(),
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: CachedNetworkImage(
                  imageUrl: track.coverUrl ?? '',
                  width: 44, height: 44, fit: BoxFit.cover,
                  errorWidget: (_, __, ___) => Container(
                    width: 44, height: 44, color: AppColors.surfaceVariant,
                    child: const Icon(Icons.music_note),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 120,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(track.title,
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                        overflow: TextOverflow.ellipsis),
                    Text(track.artist,
                        style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
                        overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
            ],
          ),
        ),
        const Spacer(),
        IconButton(
          icon: const Icon(Icons.skip_previous, size: 26),
          onPressed: () => ref.read(playerProvider.notifier).previous(),
        ),
        _PlayButton(isPlaying: player.isPlaying),
        IconButton(
          icon: const Icon(Icons.skip_next, size: 26),
          onPressed: () => ref.read(playerProvider.notifier).next(),
        ),
      ],
    );
  }
}

// ── Botão play/pause ───────────────────────────────────────────────────────

class _PlayButton extends ConsumerWidget {
  final bool isPlaying;
  const _PlayButton({required this.isPlaying});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      width: 36,
      height: 36,
      decoration: const BoxDecoration(color: AppColors.primary, shape: BoxShape.circle),
      child: IconButton(
        padding: EdgeInsets.zero,
        icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow,
            color: Colors.black, size: 20),
        onPressed: () => ref.read(playerProvider.notifier).togglePlayPause(),
      ),
    );
  }
}

// ── Controle de volume ─────────────────────────────────────────────────────

class _VolumeControl extends ConsumerStatefulWidget {
  const _VolumeControl();

  @override
  ConsumerState<_VolumeControl> createState() => _VolumeControlState();
}

class _VolumeControlState extends ConsumerState<_VolumeControl> {
  bool _muted = false;
  double _prevVolume = 1.0;

  void _toggleMute() {
    final notifier = ref.read(playerProvider.notifier);
    if (_muted) {
      notifier.setVolume(_prevVolume);
      setState(() => _muted = false);
    } else {
      _prevVolume = ref.read(playerProvider).volume;
      notifier.setVolume(0);
      setState(() => _muted = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final volume = ref.watch(playerProvider).volume;
    final icon = _muted || volume == 0
        ? Icons.volume_off
        : volume < 0.5
            ? Icons.volume_down
            : Icons.volume_up;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: Icon(icon, size: 20, color: AppColors.textSecondary),
          tooltip: _muted ? 'Ativar som' : 'Silenciar',
          onPressed: _toggleMute,
        ),
        SizedBox(
          width: 80,
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 8),
              activeTrackColor: AppColors.primary,
              inactiveTrackColor: AppColors.surfaceVariant,
              thumbColor: AppColors.primary,
              overlayColor: AppColors.primary.withOpacity(0.2),
            ),
            child: Slider(
              value: volume.clamp(0.0, 1.0),
              onChanged: (v) {
                if (_muted) setState(() => _muted = false);
                ref.read(playerProvider.notifier).setVolume(v);
              },
            ),
          ),
        ),
      ],
    );
  }
}

// ── Seek row com timestamps ────────────────────────────────────────────────

class _SeekRow extends ConsumerStatefulWidget {
  final PlayerState player;
  const _SeekRow({required this.player});

  @override
  ConsumerState<_SeekRow> createState() => _SeekRowState();
}

class _SeekRowState extends ConsumerState<_SeekRow> {
  double? _dragging;

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final value = (_dragging ?? widget.player.progress).clamp(0.0, 1.0);
    final pos = _dragging != null
        ? Duration(milliseconds: (_dragging! * widget.player.duration.inMilliseconds).round())
        : widget.player.position;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Text(_fmt(pos), style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 8),
                activeTrackColor: AppColors.primary,
                inactiveTrackColor: AppColors.surfaceVariant,
                thumbColor: AppColors.primary,
                overlayColor: AppColors.primary.withOpacity(0.2),
              ),
              child: Slider(
                value: value,
                onChangeStart: (v) => setState(() => _dragging = v),
                onChanged: (v) => setState(() => _dragging = v),
                onChangeEnd: (v) {
                  setState(() => _dragging = null);
                  final ms = (v * widget.player.duration.inMilliseconds).round();
                  ref.read(playerProvider.notifier).seekTo(Duration(milliseconds: ms));
                },
              ),
            ),
          ),
          Text(_fmt(widget.player.duration),
              style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
        ],
      ),
    );
  }
}

// ── Queue sheet modal ──────────────────────────────────────────────────────

class _QueueSheet extends ConsumerWidget {
  final List<Track> queue;
  final int currentIndex;
  const _QueueSheet({required this.queue, required this.currentIndex});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.95,
      expand: false,
      builder: (_, ctrl) => Column(
        children: [
          const SizedBox(height: 8),
          Container(
            width: 40, height: 4,
            decoration: BoxDecoration(
              color: AppColors.textSecondary.withOpacity(0.4),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                Text('Fila de reprodução', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                Text('${queue.length} músicas',
                    style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              controller: ctrl,
              itemCount: queue.length,
              itemBuilder: (_, i) {
                final t = queue[i];
                final isCurrent = i == currentIndex;
                return ListTile(
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: CachedNetworkImage(
                      imageUrl: t.coverUrl ?? '',
                      width: 44, height: 44, fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => Container(
                        width: 44, height: 44, color: AppColors.surfaceVariant,
                        child: const Icon(Icons.music_note, size: 20),
                      ),
                    ),
                  ),
                  title: Text(t.title,
                      style: TextStyle(
                          color: isCurrent ? AppColors.primary : AppColors.textPrimary,
                          fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal),
                      overflow: TextOverflow.ellipsis),
                  subtitle: Text(t.artist,
                      style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
                      overflow: TextOverflow.ellipsis),
                  trailing: isCurrent
                      ? const Icon(Icons.equalizer, color: AppColors.primary, size: 20)
                      : Text(_fmt(Duration(milliseconds: t.durationMs ?? 0)),
                          style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                  onTap: isCurrent
                      ? null
                      : () {
                          Navigator.pop(context);
                          ref.read(playerProvider.notifier).play(t, queue: queue);
                        },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
