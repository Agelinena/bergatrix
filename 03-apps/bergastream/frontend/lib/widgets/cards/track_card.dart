import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../core/theme/app_theme.dart';
import '../../models/track.dart';
import '../../models/playlist.dart';
import '../../providers/player_provider.dart';
import '../../providers/library_provider.dart';
import '../../core/api_client.dart';
import '../../screens/radio/radio_screen.dart';

class TrackCard extends ConsumerWidget {
  final Track track;
  final List<Track> queue;
  final VoidCallback? onTap;
  final String? playlistId;
  final VoidCallback? onRemoved;

  const TrackCard({
    super.key,
    required this.track,
    this.queue = const [],
    this.onTap,
    this.playlistId,
    this.onRemoved,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    final isCurrentTrack = player.currentTrack?.id == track.id;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Stack(
          children: [
            CachedNetworkImage(
              imageUrl: track.coverUrl ?? '',
              width: 48, height: 48, fit: BoxFit.cover,
              errorWidget: (_, __, ___) => Container(
                width: 48, height: 48, color: AppColors.surfaceVariant,
                child: const Icon(Icons.music_note, size: 24),
              ),
            ),
            if (isCurrentTrack)
              Container(
                width: 48, height: 48,
                color: Colors.black45,
                child: const Icon(Icons.equalizer, color: AppColors.primary, size: 24),
              ),
          ],
        ),
      ),
      title: Text(
        track.title,
        style: TextStyle(
          color: isCurrentTrack ? AppColors.primary : AppColors.textPrimary,
          fontWeight: FontWeight.w500,
        ),
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(track.artist, style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
        overflow: TextOverflow.ellipsis),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(track.durationFormatted, style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.more_vert, color: AppColors.textSecondary, size: 20),
            onPressed: () => _showTrackMenu(context, ref),
          ),
        ],
      ),
      onTap: onTap ?? () => _playTrack(ref),
    );
  }

  void _playTrack(WidgetRef ref) async {
    final client = ref.read(apiClientProvider);
    await client.registerTrack(track.toJson());
    final q = queue.isEmpty ? [track] : queue;
    await ref.read(playerProvider.notifier).play(track, queue: q);

    // Prefetch next 10
    final idx = q.indexWhere((t) => t.id == track.id);
    final nextIds = q.skip(idx + 1).take(10).map((t) => t.id).toList();
    if (nextIds.isNotEmpty) client.prefetchTracks(nextIds);
  }

  void _showTrackMenu(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surfaceVariant,
      builder: (_) => TrackMenuSheet(track: track, playlistId: playlistId, onRemoved: onRemoved),
    );
  }
}

class TrackMenuSheet extends ConsumerWidget {
  final Track track;
  final String? playlistId;
  final VoidCallback? onRemoved;
  const TrackMenuSheet({super.key, required this.track, this.playlistId, this.onRemoved});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.read(apiClientProvider);

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.play_arrow),
            title: const Text('Tocar agora'),
            onTap: () {
              Navigator.pop(context);
              client.registerTrack(track.toJson()).then((_) =>
                ref.read(playerProvider.notifier).play(track));
            },
          ),
          ListTile(
            leading: const Icon(Icons.queue_music),
            title: const Text('Adicionar à fila'),
            onTap: () {
              Navigator.pop(context);
              ref.read(playerProvider.notifier).addToQueue(track);
            },
          ),
          if (playlistId != null)
            ListTile(
              leading: const Icon(Icons.remove_circle_outline, color: Colors.redAccent),
              title: const Text('Remover da playlist', style: TextStyle(color: Colors.redAccent)),
              onTap: () async {
                Navigator.pop(context);
                await client.removeTrackFromPlaylist(playlistId!, track.id);
                onRemoved?.call();
              },
            ),
          ListTile(
            leading: const Icon(Icons.favorite_border),
            title: const Text('Curtir'),
            onTap: () {
              Navigator.pop(context);
              client.likeTrack(track.id);
            },
          ),
          ListTile(
            leading: const Icon(Icons.radio),
            title: const Text('Modo Rádio'),
            onTap: () {
              Navigator.pop(context);
              // Open synchronously — registering the track happens inside RadioScreen
              // before the seed request so there's no race with the sheet animation.
              showModalBottomSheet(
                context: context,
                useRootNavigator: true,
                isScrollControlled: true,
                backgroundColor: Colors.transparent,
                builder: (_) => DraggableScrollableSheet(
                  initialChildSize: 0.9,
                  minChildSize: 0.5,
                  maxChildSize: 1.0,
                  builder: (_, ctrl) => ClipRRect(
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                    child: RadioScreen(seedTrack: track),
                  ),
                ),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.playlist_add),
            title: const Text('Adicionar a playlist'),
            onTap: () {
              Navigator.pop(context);
              showModalBottomSheet(
                context: context,
                backgroundColor: AppColors.surfaceVariant,
                builder: (_) => _AddToPlaylistSheet(track: track),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.refresh),
            title: const Text('Baixar novamente'),
            onTap: () async {
              // Capture messenger before pop — context is deactivated after dismiss
              final messenger = ScaffoldMessenger.of(context);
              Navigator.pop(context);
              try {
                await client.deleteTrackCache(track.id);
                messenger.showSnackBar(
                  const SnackBar(
                    content: Text('Cache apagado — toque a música para re-baixar'),
                    duration: Duration(seconds: 3),
                  ),
                );
              } catch (_) {
                messenger.showSnackBar(
                  const SnackBar(content: Text('Erro ao apagar cache'), duration: Duration(seconds: 2)),
                );
              }
            },
          ),
        ],
      ),
    );
  }
}

class _AddToPlaylistSheet extends ConsumerStatefulWidget {
  final Track track;
  const _AddToPlaylistSheet({required this.track});

  @override
  ConsumerState<_AddToPlaylistSheet> createState() => _AddToPlaylistSheetState();
}

class _AddToPlaylistSheetState extends ConsumerState<_AddToPlaylistSheet> {
  String? _adding;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(libraryProvider.notifier).load();
    });
  }

  Future<void> _add(Playlist playlist, {bool force = false}) async {
    setState(() => _adding = playlist.id);
    try {
      final client = ref.read(apiClientProvider);
      await client.registerTrack(widget.track.toJson());
      await client.addTrackToPlaylist(playlist.id, widget.track.id, force: force);
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Adicionada a "${playlist.name}"'), duration: const Duration(seconds: 2)),
        );
      }
    } on DioException catch (e) {
      if (e.response?.statusCode == 409 && mounted) {
        setState(() => _adding = null);
        final confirm = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            backgroundColor: AppColors.surfaceVariant,
            title: const Text('Música já adicionada'),
            content: Text('"${widget.track.title}" já está em "${playlist.name}". Quer adicionar de novo?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
              ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Adicionar mesmo assim')),
            ],
          ),
        );
        if (confirm == true && mounted) await _add(playlist, force: true);
      } else {
        if (mounted) setState(() => _adding = null);
      }
    } catch (_) {
      if (mounted) setState(() => _adding = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final library = ref.watch(libraryProvider);
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text('Adicionar a playlist', style: Theme.of(context).textTheme.titleMedium),
          ),
          const Divider(height: 1),
          library.when(
            data: (playlists) => playlists.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('Nenhuma playlist encontrada', style: TextStyle(color: AppColors.textSecondary)),
                  )
                : ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.5),
                    child: ListView(
                      shrinkWrap: true,
                      children: playlists.map((pl) => ListTile(
                        leading: Container(
                          width: 40, height: 40,
                          color: AppColors.background,
                          child: pl.coverUrl != null
                              ? Image.network(pl.coverUrl!, fit: BoxFit.cover)
                              : const Icon(Icons.queue_music, size: 20, color: AppColors.textSecondary),
                        ),
                        title: Text(pl.name),
                        subtitle: Text('${pl.trackCount} músicas', style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                        trailing: _adding == pl.id
                            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                            : null,
                        onTap: _adding != null ? null : () => _add(pl),
                      )).toList(),
                    ),
                  ),
            loading: () => const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator(color: AppColors.primary))),
            error: (_, __) => const Padding(padding: EdgeInsets.all(24), child: Text('Erro ao carregar playlists')),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
