import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/format.dart';
import '../core/http.dart';
import '../core/widgets.dart';
import '../data/api.dart';
import '../data/models.dart';
import '../feeds/add_feed.dart';
import '../feeds/feeds_tabs.dart';

/// Ajustes → Veículos.
class SubscriptionsScreen extends ConsumerWidget {
  const SubscriptionsScreen({super.key});

  Future<void> _run(
    BuildContext context,
    WidgetRef ref,
    Future<void> Function() action,
    String done,
  ) async {
    try {
      await action();
      ref.invalidate(subscriptionsProvider);
      ref.invalidate(foldersProvider);
      if (context.mounted) toast(context, done);
    } on Object catch (e) {
      if (context.mounted) toast(context, describeError(e));
    }
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    Subscription sub,
    List<Folder> folders,
  ) async {
    final api = ref.read(apiProvider);
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(sub.title, style: Theme.of(context).textTheme.titleMedium),
              subtitle: Text(sub.url, maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Renomear'),
              onTap: () => Navigator.pop(context, 'rename'),
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_move_outline),
              title: const Text('Mudar de pasta'),
              onTap: () => Navigator.pop(context, 'folder'),
            ),
            ListTile(
              leading: const Icon(Icons.sync),
              title: const Text('Buscar matérias novas agora'),
              onTap: () => Navigator.pop(context, 'refresh'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Deixar de assinar'),
              onTap: () => Navigator.pop(context, 'remove'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !context.mounted) return;
    switch (action) {
      case 'rename':
        final name = await askText(
          context,
          title: 'Nome do veículo',
          initial: sub.title,
        );
        if (name == null || !context.mounted) return;
        await _run(context, ref, () => api.updateSubscription(sub.feedId, title: name), 'Renomeado');
      case 'folder':
        final chosen = await showDialog<int>(
          context: context,
          builder: (context) => SimpleDialog(
            title: const Text('Mudar para a pasta'),
            children: [
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, -1),
                child: const Text('Sem pasta'),
              ),
              for (final f in folders)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, f.id),
                  child: Text(f.name),
                ),
            ],
          ),
        );
        if (chosen == null || !context.mounted) return;
        await _run(
          context,
          ref,
          () => chosen == -1
              ? api.updateSubscription(sub.feedId, clearFolder: true)
              : api.updateSubscription(sub.feedId, folderId: chosen),
          'Pasta trocada',
        );
      case 'refresh':
        await _run(context, ref, () => api.refreshFeed(sub.feedId), 'Buscando matérias novas…');
      case 'remove':
        final ok = await confirm(
          context,
          title: 'Deixar de assinar ${sub.title}?',
          message: 'Os artigos salvos continuam nos Salvos.',
          ok: 'Deixar de assinar',
        );
        if (!ok || !context.mounted) return;
        await _run(context, ref, () => api.unsubscribe(sub.feedId), 'Removido');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subs = ref.watch(subscriptionsProvider);
    final folders = ref.watch(foldersProvider).value ?? const <Folder>[];
    final names = {for (final f in folders) f.id: f.name};
    return Scaffold(
      appBar: AppBar(title: const Text('Veículos')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showAddFeed(context),
        icon: const Icon(Icons.add),
        label: const Text('Adicionar'),
      ),
      body: subs.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) =>
            ErrorView(e, onRetry: () => ref.invalidate(subscriptionsProvider)),
        data: (list) => list.isEmpty
            ? const MessageView(
                icon: Icons.rss_feed,
                title: 'Nenhum veículo',
                message: 'Adicione pelo endereço do site, ou importe um OPML em Ajustes.',
              )
            : ListView.builder(
                padding: const EdgeInsets.only(bottom: 96),
                itemCount: list.length,
                itemBuilder: (context, i) {
                  final s = list[i];
                  final details = [
                    names[s.folderId] ?? 'Sem pasta',
                    if (s.lastFetchedAt != null)
                      'coletado ${relativeTime(s.lastFetchedAt!)}',
                  ].join(' · ');
                  return ListTile(
                    title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      s.error == null ? details : 'Com problema: ${s.error}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: s.error == null
                          ? null
                          : TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                    trailing: const Icon(Icons.more_vert),
                    onTap: () => _edit(context, ref, s, folders),
                  );
                },
              ),
      ),
    );
  }
}

/// Ajustes → Pastas.
class FoldersScreen extends ConsumerWidget {
  const FoldersScreen({super.key});

  Future<void> _run(BuildContext context, WidgetRef ref, Future<void> Function() action) async {
    try {
      await action();
      ref.invalidate(foldersProvider);
      ref.invalidate(subscriptionsProvider);
    } on Object catch (e) {
      if (context.mounted) toast(context, describeError(e));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.read(apiProvider);
    final folders = ref.watch(foldersProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Pastas')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final name = await askText(context, title: 'Nova pasta', label: 'Nome', ok: 'Criar');
          if (name == null || !context.mounted) return;
          await _run(context, ref, () => api.createFolder(name));
        },
        icon: const Icon(Icons.create_new_folder_outlined),
        label: const Text('Nova pasta'),
      ),
      body: folders.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorView(e, onRetry: () => ref.invalidate(foldersProvider)),
        data: (list) => list.isEmpty
            ? const MessageView(
                icon: Icons.folder_outlined,
                title: 'Nenhuma pasta',
                message: 'Pastas agrupam veículos (ex.: Brasil, Mundo, Tecnologia).',
              )
            : ListView(
                padding: const EdgeInsets.only(bottom: 96),
                children: [
                  for (final f in list)
                    ListTile(
                      leading: const Icon(Icons.folder_outlined),
                      title: Text(f.name),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Renomear',
                            icon: const Icon(Icons.edit_outlined),
                            onPressed: () async {
                              final name = await askText(context, title: 'Renomear pasta', initial: f.name);
                              if (name == null || !context.mounted) return;
                              await _run(context, ref, () => api.renameFolder(f.id, name));
                            },
                          ),
                          IconButton(
                            tooltip: 'Apagar',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () async {
                              final ok = await confirm(
                                context,
                                title: 'Apagar a pasta ${f.name}?',
                                message: 'Os veículos dela continuam, sem pasta.',
                                ok: 'Apagar',
                              );
                              if (!ok || !context.mounted) return;
                              await _run(context, ref, () => api.deleteFolder(f.id));
                            },
                          ),
                        ],
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}

final _usersProvider = FutureProvider.autoDispose<List<AdminUser>>(
  (ref) => ref.watch(apiProvider).users(),
);

/// Ajustes → Usuários (admin). As contas vêm do Authentik; aqui só se
/// desativa, reativa e desconecta.
class UsersScreen extends ConsumerWidget {
  const UsersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final users = ref.watch(_usersProvider);
    final api = ref.read(apiProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Usuários')),
      body: users.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorView(e, onRetry: () => ref.invalidate(_usersProvider)),
        data: (list) => ListView(
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Text(
                'Quem está no grupo berganews_users do Authentik entra e ganha a conta no '
                '1º login. Para tirar o acesso: tire do grupo no Authentik e desative aqui.',
              ),
            ),
            for (final u in list)
              ListTile(
                leading: CircleAvatar(
                  child: Text(u.name.isEmpty ? '?' : u.name[0].toUpperCase()),
                ),
                title: Text(u.isAdmin ? '${u.name} (admin)' : u.name),
                subtitle: Text(
                  [
                    u.email ?? u.username,
                    plural(u.subscriptions, 'veículo', 'veículos'),
                    plural(u.sessions, 'aparelho', 'aparelhos'),
                    if (u.lastLoginAt != null) 'entrou ${relativeTime(u.lastLoginAt!)}',
                    if (u.disabled) 'desativada',
                  ].join(' · '),
                ),
                trailing: PopupMenuButton<String>(
                  onSelected: (action) async {
                    try {
                      if (action == 'toggle') {
                        await api.setUserDisabled(u.id, !u.disabled);
                      } else {
                        await api.logoutUser(u.id);
                      }
                      ref.invalidate(_usersProvider);
                      if (context.mounted) toast(context, 'Feito');
                    } on Object catch (e) {
                      if (context.mounted) toast(context, describeError(e));
                    }
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: 'toggle',
                      child: Text(u.disabled ? 'Reativar a conta' : 'Desativar a conta'),
                    ),
                    const PopupMenuItem(
                      value: 'logout',
                      child: Text('Desconectar os aparelhos'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
