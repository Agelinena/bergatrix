import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../core/theme/app_theme.dart';
import '../../models/track.dart';
import '../../models/playlist.dart';
import '../../providers/player_provider.dart';
import '../../providers/radio_queue_provider.dart';
import '../../providers/library_provider.dart';
import '../../providers/liked_provider.dart';
import '../../core/api_client.dart';
import '../../core/error_messages.dart';
import '../../screens/radio/radio_screen.dart';

class TrackCard extends ConsumerWidget {
  final Track track;
  final List<Track> queue;
  final VoidCallback? onTap;
  final String? playlistId;
  final VoidCallback? onRemoved;
  final bool showRadioOption;

  const TrackCard({
    super.key,
    required this.track,
    this.queue = const [],
    this.onTap,
    this.playlistId,
    this.onRemoved,
    this.showRadioOption = true,
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
    // Desativa rádio ao tocar de playlist/biblioteca (rádio só ativa na busca)
    ref.read(radioQueueProvider.notifier).deactivate();

    final client = ref.read(apiClientProvider);
    client.registerTrack(track.toJson()).ignore(); // fire-and-forget: preserve user gesture
    final q = queue.isEmpty ? [track] : queue;
    await ref.read(playerProvider.notifier).play(track, queue: q);

    // Prefetch next 10 — send full Track objects so the backend can
    // auto-register any that aren't in the DB yet (radio suggestions, etc.).
    final idx = q.indexWhere((t) => t.id == track.id);
    final nextTracks = q.skip(idx + 1).take(10).toList();
    if (nextTracks.isNotEmpty) {
      client.prefetchTracks(
        nextTracks.map((t) => t.id).toList(),
        tracks: nextTracks,
      );
    }
  }

  void _showTrackMenu(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surfaceVariant,
      builder: (_) => TrackMenuSheet(track: track, playlistId: playlistId, onRemoved: onRemoved, showRadioOption: showRadioOption),
    );
  }
}

class TrackMenuSheet extends ConsumerWidget {
  final Track track;
  final String? playlistId;
  final VoidCallback? onRemoved;
  final bool showRadioOption;
  const TrackMenuSheet({super.key, required this.track, this.playlistId, this.onRemoved, this.showRadioOption = true});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.read(apiClientProvider);
    final isLiked = ref.watch(likedProvider.select((s) => s.contains(track.id)));

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Cabeçalho ────────────────────────────────────────────────────
          ListTile(
            leading: track.coverUrl != null
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Image.network(track.coverUrl!, width: 40, height: 40, fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const Icon(Icons.music_note)),
                  )
                : const Icon(Icons.music_note),
            title: Text(track.title, style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text(track.artist, style: const TextStyle(color: AppColors.textSecondary)),
          ),
          const Divider(height: 1),

          // ── Ações ─────────────────────────────────────────────────────────
          ListTile(
            leading: const Icon(Icons.play_arrow),
            title: const Text('Tocar agora'),
            onTap: () {
              Navigator.pop(context);
              client.registerTrack(track.toJson()).then((_) {
                ref.read(radioQueueProvider.notifier).deactivate();
                ref.read(playerProvider.notifier).play(track);
              });
            },
          ),
          ListTile(
            leading: const Icon(Icons.queue_music),
            title: const Text('Tocar a seguir'),
            onTap: () {
              Navigator.pop(context);
              ref.read(playerProvider.notifier).insertNextInQueue(track);
            },
          ),

          // ── Curtir ────────────────────────────────────────────────────────
          ListTile(
            leading: Icon(
              isLiked ? Icons.favorite : Icons.favorite_border,
              color: isLiked ? Colors.pinkAccent : null,
            ),
            title: Text(isLiked ? 'Descurtir' : 'Curtir'),
            onTap: () {
              Navigator.pop(context);
              ref.read(likedProvider.notifier).toggle(track.id);
            },
          ),

          // ── Compartilhar ──────────────────────────────────────────────────
          ListTile(
            leading: const Icon(Icons.share_outlined),
            title: const Text('Compartilhar'),
            onTap: () {
              Navigator.pop(context);
              _showShareSheet(context, ref);
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
          if (showRadioOption)
            ListTile(
              leading: const Icon(Icons.radio),
              title: const Text('Modo Rádio'),
              onTap: () {
                Navigator.pop(context);
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
              final messenger = ScaffoldMessenger.of(context);
              Navigator.pop(context);
              try {
                await client.deleteTrackCache(track.id);
                messenger.showSnackBar(const SnackBar(
                  content: Text('Cache apagado — toque para re-baixar'),
                  duration: Duration(seconds: 3),
                ));
              } catch (_) {
                messenger.showSnackBar(const SnackBar(
                  content: Text('Não foi possível apagar o cache'),
                  duration: Duration(seconds: 2),
                ));
              }
            },
          ),
        ],
      ),
    );
  }

  // ── Share sheet ───────────────────────────────────────────────────────────

  void _showShareSheet(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surfaceVariant,
      builder: (_) => _ShareSheet(track: track),
    );
  }
}

class _ShareSheet extends StatelessWidget {
  final Track track;
  const _ShareSheet({required this.track});

  String? _spotifyUrl() {
    if (track.source == 'spotify' && track.sourceId != null) {
      return 'https://open.spotify.com/track/${track.sourceId}';
    }
    return null;
  }

  String? _deezerUrl() {
    if (track.source == 'deezer' && track.sourceId != null) {
      return 'https://www.deezer.com/track/${track.sourceId}';
    }
    return null;
  }

  String _bergaUrl() {
    final q = Uri.encodeQueryComponent('${track.title} ${track.artist}');
    return 'https://stream.bergaestudio.xyz/search?q=$q';
  }

  void _copy(BuildContext context, String url, String platform) {
    Clipboard.setData(ClipboardData(text: url));
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Link do $platform copiado!'),
      duration: const Duration(seconds: 2),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final spotifyUrl = _spotifyUrl();
    final deezerUrl = _deezerUrl();

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text('Compartilhar "${track.title}"',
                style: Theme.of(context).textTheme.titleMedium),
          ),
          const Divider(height: 1),
          if (spotifyUrl != null)
            ListTile(
              leading: const Icon(Icons.music_note, color: Color(0xFF1DB954)),
              title: const Text('Spotify'),
              subtitle: Text(spotifyUrl, style: const TextStyle(fontSize: 11, color: AppColors.textSecondary), overflow: TextOverflow.ellipsis),
              onTap: () => _copy(context, spotifyUrl, 'Spotify'),
              trailing: const Icon(Icons.copy, size: 18),
            ),
          if (deezerUrl != null)
            ListTile(
              leading: const Icon(Icons.music_note, color: Color(0xFFEF5466)),
              title: const Text('Deezer'),
              subtitle: Text(deezerUrl, style: const TextStyle(fontSize: 11, color: AppColors.textSecondary), overflow: TextOverflow.ellipsis),
              onTap: () => _copy(context, deezerUrl, 'Deezer'),
              trailing: const Icon(Icons.copy, size: 18),
            ),
          ListTile(
            leading: const Icon(Icons.music_note, color: AppColors.primary),
            title: const Text('BergaStream'),
            subtitle: Text(_bergaUrl(), style: const TextStyle(fontSize: 11, color: AppColors.textSecondary), overflow: TextOverflow.ellipsis),
            onTap: () => _copy(context, _bergaUrl(), 'BergaStream'),
            trailing: const Icon(Icons.copy, size: 18),
          ),
          const SizedBox(height: 8),
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

  Future<void> _createAndAdd() async {
    final nameCtrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceVariant,
        title: const Text('Nova playlist'),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Nome da playlist'),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, nameCtrl.text.trim()),
            child: const Text('Criar'),
          ),
        ],
      ),
    );
    nameCtrl.dispose();
    if (name == null || name.isEmpty || !mounted) return;

    setState(() => _adding = '__new__');
    try {
      final client = ref.read(apiClientProvider);
      await client.registerTrack(widget.track.toJson());
      final newPlaylist = await client.createPlaylist(name);
      final newId = newPlaylist['id'] as String;
      await client.addTrackToPlaylist(newId, widget.track.id);
      await ref.read(libraryProvider.notifier).load();
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Playlist "$name" criada e música adicionada'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (_) {
      if (mounted) setState(() => _adding = null);
    }
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
          ListTile(
            leading: const Icon(Icons.add_circle_outline, color: AppColors.primary),
            title: const Text('Nova playlist', style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w600)),
            onTap: _adding != null ? null : _createAndAdd,
            trailing: _adding == '__new__'
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : null,
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
