// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_theme.dart';
import '../../core/api_client.dart';
import '../../models/playlist.dart';
import '../../providers/player_provider.dart';
import '../../providers/library_provider.dart';
import '../../widgets/cards/track_card.dart';

class PlaylistScreen extends ConsumerStatefulWidget {
  final String id;
  const PlaylistScreen({super.key, required this.id});

  @override
  ConsumerState<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends ConsumerState<PlaylistScreen> {
  Playlist? _playlist;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final client = ref.read(apiClientProvider);
      final data = await client.getPlaylist(widget.id);
      setState(() { _playlist = Playlist.fromJson(data); _loading = false; });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  void _playAll() {
    if (_playlist == null) return;
    final tracks = _playlist!.tracks.map((pt) => pt.track).toList();
    if (tracks.isNotEmpty) {
      ref.read(playerProvider.notifier).play(tracks.first, queue: tracks);
    }
  }

  void _shuffle() {
    if (_playlist == null) return;
    final tracks = [..._playlist!.tracks.map((pt) => pt.track)]..shuffle();
    if (tracks.isNotEmpty) {
      ref.read(playerProvider.notifier).play(tracks.first, queue: tracks);
      ref.read(playerProvider.notifier).toggleShuffle();
    }
  }

  void _showEditDialog() {
    if (_playlist == null) return;
    showDialog(
      context: context,
      builder: (_) => _EditPlaylistDialog(
        playlistId: widget.id,
        playlist: _playlist!,
        onSaved: (name, description, coverUrl, isPublic) async {
          await ref.read(libraryProvider.notifier).updatePlaylist(
            widget.id,
            name: name,
            description: description,
            coverUrl: coverUrl,
            isPublic: isPublic,
          );
          await _load();
        },
      ),
    );
  }

  Future<void> _share() async {
    try {
      final client = ref.read(apiClientProvider);
      final data = await client.sharePlaylist(widget.id);
      final url = data['share_url'] as String? ?? '';
      if (mounted && url.isNotEmpty) {
        await Clipboard.setData(ClipboardData(text: url));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Link copiado!'), duration: Duration(seconds: 2)),
        );
      }
    } catch (_) {}
  }

  Future<void> _delete() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surfaceVariant,
        title: const Text('Deletar playlist?'),
        content: Text('Tem certeza que quer deletar "${_playlist?.name}"? Isso não pode ser desfeito.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Deletar'),
          ),
        ],
      ),
    );
    if (confirm == true && mounted) {
      await ref.read(libraryProvider.notifier).deletePlaylist(widget.id);
      if (mounted) context.go('/library');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator(color: AppColors.primary)));
    if (_playlist == null) return const Scaffold(body: Center(child: Text('Playlist não encontrada')));

    final pl = _playlist!;
    final tracks = pl.tracks.map((pt) => pt.track).toList();
    final totalDuration = tracks.fold(0, (sum, t) => sum + (t.durationMs ?? 0));
    final totalMin = totalDuration ~/ 60000;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 280,
            pinned: true,
            actions: [
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert),
                onSelected: (v) {
                  if (v == 'edit') _showEditDialog();
                  if (v == 'share') _share();
                  if (v == 'delete') _delete();
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'edit', child: ListTile(leading: Icon(Icons.edit_outlined), title: Text('Editar'))),
                  const PopupMenuItem(value: 'share', child: ListTile(leading: Icon(Icons.share_outlined), title: Text('Compartilhar'))),
                  const PopupMenuItem(value: 'delete', child: ListTile(leading: Icon(Icons.delete_outline, color: Colors.red), title: Text('Deletar', style: TextStyle(color: Colors.red)))),
                ],
              ),
            ],
            flexibleSpace: FlexibleSpaceBar(
              background: Stack(
                fit: StackFit.expand,
                children: [
                  pl.coverUrl != null
                      ? CachedNetworkImage(imageUrl: pl.coverUrl!, fit: BoxFit.cover)
                      : Container(color: AppColors.surfaceVariant, child: const Icon(Icons.queue_music, size: 80)),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, AppColors.background],
                      ),
                    ),
                  ),
                  Positioned(
                    bottom: 16, left: 16, right: 16,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(pl.name, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                        if (pl.description != null && pl.description!.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(pl.description!, style: const TextStyle(color: AppColors.textSecondary, fontSize: 13), maxLines: 2, overflow: TextOverflow.ellipsis),
                          ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Text('${tracks.length} músicas · $totalMin min', style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                            if (pl.isPublic) ...[
                              const SizedBox(width: 8),
                              const Icon(Icons.public, size: 14, color: AppColors.textSecondary),
                              const SizedBox(width: 2),
                              const Text('Pública', style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  ElevatedButton.icon(
                    onPressed: _shuffle,
                    icon: const Icon(Icons.shuffle, size: 18),
                    label: const Text('Aleatório'),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: _playAll,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Tocar tudo'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.textPrimary,
                      side: const BorderSide(color: AppColors.textSecondary),
                      shape: const StadiumBorder(),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (_, i) => TrackCard(
                track: tracks[i],
                queue: tracks,
                playlistId: widget.id,
                onRemoved: _load,
              ),
              childCount: tracks.length,
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 80)),
        ],
      ),
    );
  }
}

class _EditPlaylistDialog extends StatefulWidget {
  final String playlistId;
  final Playlist playlist;
  final Future<void> Function(String? name, String? description, String? coverUrl, bool? isPublic) onSaved;

  const _EditPlaylistDialog({required this.playlistId, required this.playlist, required this.onSaved});

  @override
  State<_EditPlaylistDialog> createState() => _EditPlaylistDialogState();
}

class _EditPlaylistDialogState extends State<_EditPlaylistDialog> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _descCtrl;
  late final TextEditingController _coverCtrl;
  late bool _isPublic;
  bool _loading = false;
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.playlist.name);
    _descCtrl = TextEditingController(text: widget.playlist.description ?? '');
    _coverCtrl = TextEditingController(text: widget.playlist.coverUrl ?? '');
    _isPublic = widget.playlist.isPublic;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    _coverCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickCover() async {
    final input = html.FileUploadInputElement()
      ..accept = 'image/jpeg,image/png,image/webp';
    input.click();
    await input.onChange.first;
    final file = input.files?.first;
    if (file == null || !mounted) return;

    setState(() => _uploading = true);
    try {
      final reader = html.FileReader();
      reader.readAsArrayBuffer(file);
      await reader.onLoad.first;

      final buffer = reader.result as html.ByteBuffer;
      final bytes = buffer.asUint8List();
      final mimeType = file.type.isNotEmpty ? file.type : 'image/jpeg';

      // We don't have ref here — use a workaround via callback
      // The ApiClient instance is used through the parent's onSaved
      // For cover upload, we need direct access — handled via mounted context
      _uploadCoverBytes(bytes, mimeType);
    } catch (_) {
      if (mounted) setState(() => _uploading = false);
    }
  }

  // Separate method so we can call it after await
  void _uploadCoverBytes(Uint8List bytes, String mimeType) async {
    // Access ApiClient directly without ref (it's stateless)
    try {
      final client = ApiClient();
      final url = await client.uploadPlaylistCover(widget.playlistId, bytes, mimeType);
      if (url != null && mounted) {
        setState(() {
          _coverCtrl.text = url;
          _uploading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surfaceVariant,
      title: const Text('Editar playlist'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: _nameCtrl, decoration: const InputDecoration(labelText: 'Nome')),
            const SizedBox(height: 12),
            TextField(controller: _descCtrl, decoration: const InputDecoration(labelText: 'Descrição'), maxLines: 2),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: TextField(controller: _coverCtrl, decoration: const InputDecoration(labelText: 'URL da capa'))),
                const SizedBox(width: 8),
                _uploading
                    ? const SizedBox(width: 36, height: 36, child: CircularProgressIndicator(strokeWidth: 2))
                    : IconButton(
                        icon: const Icon(Icons.upload_file),
                        tooltip: 'Enviar arquivo',
                        onPressed: _pickCover,
                      ),
              ],
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Playlist pública', style: TextStyle(fontSize: 14)),
              value: _isPublic,
              onChanged: (v) => setState(() => _isPublic = v),
              activeColor: AppColors.primary,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        ElevatedButton(
          onPressed: _loading ? null : () async {
            setState(() => _loading = true);
            await widget.onSaved(
              _nameCtrl.text.trim().isNotEmpty ? _nameCtrl.text.trim() : null,
              _descCtrl.text.trim(),
              _coverCtrl.text.trim().isNotEmpty ? _coverCtrl.text.trim() : null,
              _isPublic,
            );
            if (mounted) Navigator.pop(context);
          },
          child: _loading
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Salvar'),
        ),
      ],
    );
  }
}
