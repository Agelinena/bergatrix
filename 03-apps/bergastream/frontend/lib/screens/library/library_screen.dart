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
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surfaceVariant,
        title: const Text('Nova playlist'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Nome da playlist'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
          ElevatedButton(
            onPressed: () async {
              if (ctrl.text.isNotEmpty) {
                await ref.read(libraryProvider.notifier).createPlaylist(ctrl.text);
                if (mounted) Navigator.pop(context);
              }
            },
            child: const Text('Criar'),
          ),
        ],
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
