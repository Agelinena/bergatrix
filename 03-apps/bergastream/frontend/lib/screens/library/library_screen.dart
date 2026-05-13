import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_theme.dart';
import '../../providers/library_provider.dart';
import '../../models/playlist.dart';

class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(libraryProvider.notifier).load();
    });
  }

  void _showCreatePlaylistDialog() {
    showDialog(
      context: context,
      builder: (_) => _CreatePlaylistDialog(
        onCreated: (name, description, isPublic) async {
          await ref.read(libraryProvider.notifier).createPlaylist(
            name,
            description: description.isNotEmpty ? description : null,
            isPublic: isPublic,
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final library = ref.watch(libraryProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Biblioteca')),
      floatingActionButton: FloatingActionButton(
        onPressed: _showCreatePlaylistDialog,
        backgroundColor: AppColors.primary,
        child: const Icon(Icons.add, color: Colors.black),
      ),
      body: library.when(
        data: (playlists) => RefreshIndicator(
          onRefresh: () => ref.read(libraryProvider.notifier).load(),
          color: AppColors.primary,
          child: ListView(
            children: [
              // Liked songs card
              _LikedSongsCard(),
              const Divider(height: 1),
              // Playlists
              if (playlists.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: Text('Nenhuma playlist criada ainda', style: TextStyle(color: AppColors.textSecondary))),
                )
              else
                ...playlists.map((pl) => _PlaylistTile(playlist: pl)),
            ],
          ),
        ),
        loading: () => const Center(child: CircularProgressIndicator(color: AppColors.primary)),
        error: (e, _) => Center(child: Text('Erro: $e')),
      ),
    );
  }
}

class _LikedSongsCard extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      leading: Container(
        width: 56, height: 56,
        decoration: const BoxDecoration(
          gradient: LinearGradient(colors: [Color(0xFF4B2991), Color(0xFF8B5CF6)]),
          borderRadius: BorderRadius.all(Radius.circular(4)),
        ),
        child: const Icon(Icons.favorite, color: Colors.white),
      ),
      title: const Text('Músicas curtidas', style: TextStyle(fontWeight: FontWeight.w600)),
      subtitle: const Text('Playlist', style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
      onTap: () => context.go('/library/likes'),
    );
  }
}

class _PlaylistTile extends ConsumerWidget {
  final Playlist playlist;
  const _PlaylistTile({required this.playlist});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Dismissible(
      key: Key(playlist.id),
      direction: DismissDirection.endToStart,
      background: Container(
        color: Colors.red,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      confirmDismiss: (_) async {
        return await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            backgroundColor: AppColors.surfaceVariant,
            title: const Text('Deletar playlist?'),
            content: Text('Tem certeza que quer deletar "${playlist.name}"?'),
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
      },
      onDismissed: (_) => ref.read(libraryProvider.notifier).deletePlaylist(playlist.id),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Container(
          width: 56, height: 56,
          color: AppColors.surfaceVariant,
          child: playlist.coverUrl != null
              ? Image.network(playlist.coverUrl!, fit: BoxFit.cover)
              : const Icon(Icons.queue_music, color: AppColors.textSecondary),
        ),
        title: Text(playlist.name, style: const TextStyle(fontWeight: FontWeight.w500)),
        subtitle: Text('${playlist.trackCount} músicas', style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
        onTap: () => context.go('/playlist/${playlist.id}'),
      ),
    );
  }
}

class _CreatePlaylistDialog extends StatefulWidget {
  final Future<void> Function(String name, String description, bool isPublic) onCreated;
  const _CreatePlaylistDialog({required this.onCreated});

  @override
  State<_CreatePlaylistDialog> createState() => _CreatePlaylistDialogState();
}

class _CreatePlaylistDialogState extends State<_CreatePlaylistDialog> {
  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  bool _isPublic = false;
  bool _loading = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surfaceVariant,
      title: const Text('Nova playlist'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _nameCtrl,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'Nome da playlist'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _descCtrl,
            decoration: const InputDecoration(hintText: 'Descrição (opcional)'),
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
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        ElevatedButton(
          onPressed: _loading ? null : () async {
            if (_nameCtrl.text.trim().isEmpty) return;
            setState(() => _loading = true);
            await widget.onCreated(_nameCtrl.text.trim(), _descCtrl.text.trim(), _isPublic);
            if (mounted) Navigator.pop(context);
          },
          child: _loading ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Criar'),
        ),
      ],
    );
  }
}
