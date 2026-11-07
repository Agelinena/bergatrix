import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/format.dart';
import '../core/http.dart';
import '../core/widgets.dart';
import '../data/api.dart';
import '../data/models.dart';
import '../feeds/add_feed.dart';
import '../feeds/feeds_tabs.dart';
import '../feeds/manage.dart';

/// Ajustes → Veículos (a mesma lista da aba Veículos; tocar abre o menu).
class SubscriptionsScreen extends StatelessWidget {
  const SubscriptionsScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Veículos')),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: () => showAddFeed(context),
      icon: const Icon(Icons.add),
      label: const Text('Adicionar'),
    ),
    body: const SubscriptionsList(),
  );
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
