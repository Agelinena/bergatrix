import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/format.dart';
import '../core/http.dart';
import '../core/widgets.dart';
import '../data/api.dart';
import '../data/models.dart';
import 'feeds_tabs.dart';

// Ações de veículo e de pasta, usadas na aba Veículos, em Ajustes → Veículos
// e no "Adicionar veículo".

/// Escolha de pasta: devolve o id, [noFolder] para "Sem pasta" ou null se
/// desistiu. "Nova pasta…" cria e já devolve a nova.
const noFolder = -1;

Future<int?> pickFolder(
  BuildContext context,
  WidgetRef ref, {
  int? current,
  String title = 'Mudar para a pasta',
}) async {
  final folders = await ref.read(foldersProvider.future);
  if (!context.mounted) return null;
  final chosen = await showDialog<int>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text(title),
      children: [
        _FolderOption(
          label: 'Sem pasta',
          selected: current == null,
          onTap: () => Navigator.pop(context, noFolder),
        ),
        for (final f in folders)
          _FolderOption(
            label: f.name,
            selected: current == f.id,
            onTap: () => Navigator.pop(context, f.id),
          ),
        const Divider(),
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, -2),
          child: const Row(
            children: [
              Icon(Icons.create_new_folder_outlined, size: 20),
              SizedBox(width: 12),
              Text('Nova pasta…'),
            ],
          ),
        ),
      ],
    ),
  );
  if (chosen != -2 || !context.mounted) return chosen;
  final created = await createFolder(context, ref);
  return created?.id;
}

class _FolderOption extends StatelessWidget {
  const _FolderOption({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => SimpleDialogOption(
    onPressed: onTap,
    child: Row(
      children: [
        Icon(
          selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
          size: 20,
          color: selected ? Theme.of(context).colorScheme.primary : null,
        ),
        const SizedBox(width: 12),
        Expanded(child: Text(label)),
      ],
    ),
  );
}

void _refresh(WidgetRef ref) {
  ref.invalidate(subscriptionsProvider);
  ref.invalidate(foldersProvider);
}

/// Pergunta o nome e cria a pasta; null se desistiu ou falhou.
Future<Folder?> createFolder(BuildContext context, WidgetRef ref) async {
  final name = await askText(context, title: 'Nova pasta', label: 'Nome', ok: 'Criar');
  if (name == null || !context.mounted) return null;
  try {
    final folder = await ref.read(apiProvider).createFolder(name);
    _refresh(ref);
    return folder;
  } on Object catch (e) {
    if (context.mounted) toast(context, describeError(e));
    return null;
  }
}

Future<void> _run(
  BuildContext context,
  WidgetRef ref,
  Future<void> Function() action, [
  String? done,
]) async {
  try {
    await action();
    _refresh(ref);
    if (done != null && context.mounted) toast(context, done);
  } on Object catch (e) {
    if (context.mounted) toast(context, describeError(e));
  }
}

/// Menu do veículo: renomear, mudar de pasta, buscar agora, deixar de assinar.
Future<void> editSubscription(
  BuildContext context,
  WidgetRef ref,
  Subscription sub,
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
        label: 'Vazio = o nome do feed (${sub.feedTitle})',
        initial: sub.title,
      );
      if (name == null || !context.mounted) return;
      await _run(context, ref, () => api.updateSubscription(sub.feedId, title: name), 'Renomeado');
    case 'folder':
      final chosen = await pickFolder(context, ref, current: sub.folderId);
      if (chosen == null || !context.mounted) return;
      await _run(
        context,
        ref,
        () => chosen == noFolder
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

/// Menu da pasta: renomear ou apagar (os veículos ficam, sem pasta).
Future<void> editFolder(BuildContext context, WidgetRef ref, Folder folder) async {
  final api = ref.read(apiProvider);
  final action = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: Text(folder.name, style: Theme.of(context).textTheme.titleMedium),
          ),
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('Renomear a pasta'),
            onTap: () => Navigator.pop(context, 'rename'),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('Apagar a pasta'),
            onTap: () => Navigator.pop(context, 'delete'),
          ),
        ],
      ),
    ),
  );
  if (action == null || !context.mounted) return;
  if (action == 'rename') {
    final name = await askText(context, title: 'Renomear pasta', initial: folder.name);
    if (name == null || !context.mounted) return;
    await _run(context, ref, () => api.renameFolder(folder.id, name));
  } else {
    final ok = await confirm(
      context,
      title: 'Apagar a pasta ${folder.name}?',
      message: 'Os veículos dela continuam, sem pasta.',
      ok: 'Apagar',
    );
    if (!ok || !context.mounted) return;
    await _run(context, ref, () => api.deleteFolder(folder.id));
  }
}

/// Veículos agrupados por pasta, com o menu de cada um e de cada pasta.
/// [onOpen]: o que fazer ao tocar no veículo (abrir as matérias); sem ele, o
/// toque abre o menu.
class SubscriptionsList extends ConsumerWidget {
  const SubscriptionsList({super.key, this.onOpen, this.bottomPadding = 96});

  final void Function(Subscription sub)? onOpen;
  final double bottomPadding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subs = ref.watch(subscriptionsProvider);
    final folders = ref.watch(foldersProvider).value ?? const <Folder>[];
    return subs.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => ErrorView(e, onRetry: () => _refresh(ref)),
      data: (list) {
        final byFolder = <int?, List<Subscription>>{};
        for (final s in list) {
          byFolder.putIfAbsent(s.folderId, () => []).add(s);
        }
        final children = <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Wrap(
              spacing: 8,
              children: [
                ActionChip(
                  avatar: const Icon(Icons.create_new_folder_outlined, size: 18),
                  label: const Text('Nova pasta'),
                  onPressed: () => createFolder(context, ref),
                ),
              ],
            ),
          ),
        ];
        if (list.isEmpty) {
          children.add(
            const MessageView(
              icon: Icons.rss_feed,
              title: 'Você ainda não assina nenhum veículo',
              message: 'Toque em + para adicionar pelo endereço do site ou do feed.',
            ),
          );
        }
        for (final f in folders) {
          children.add(
            _FolderHeader(
              title: f.name,
              count: byFolder[f.id]?.length ?? 0,
              onMenu: () => editFolder(context, ref, f),
            ),
          );
          final inFolder = byFolder[f.id] ?? const <Subscription>[];
          if (inFolder.isEmpty) {
            children.add(
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text('Vazia. Mude um veículo para cá pelo menu ⋮ dele.'),
              ),
            );
          }
          children.addAll(inFolder.map((s) => _SubscriptionTile(sub: s, onOpen: onOpen)));
        }
        final loose = byFolder[null] ?? const <Subscription>[];
        if (loose.isNotEmpty) {
          if (folders.isNotEmpty) {
            children.add(_FolderHeader(title: 'Sem pasta', count: loose.length));
          }
          children.addAll(loose.map((s) => _SubscriptionTile(sub: s, onOpen: onOpen)));
        }
        return RefreshIndicator(
          onRefresh: () => ref.refresh(subscriptionsProvider.future),
          child: ListView(
            padding: EdgeInsets.only(bottom: bottomPadding),
            children: children,
          ),
        );
      },
    );
  }
}

class _FolderHeader extends StatelessWidget {
  const _FolderHeader({required this.title, required this.count, this.onMenu});

  final String title;
  final int count;
  final VoidCallback? onMenu;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 4, 0),
      child: Row(
        children: [
          Icon(Icons.folder_outlined, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$title · ${plural(count, 'veículo', 'veículos')}',
              style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary),
            ),
          ),
          if (onMenu != null)
            IconButton(
              tooltip: 'Pasta $title',
              onPressed: onMenu,
              icon: const Icon(Icons.more_vert),
            ),
        ],
      ),
    );
  }
}

class _SubscriptionTile extends ConsumerWidget {
  const _SubscriptionTile({required this.sub, this.onOpen});

  final Subscription sub;
  final void Function(Subscription sub)? onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final details = [
      if (sub.title != sub.feedTitle && sub.feedTitle.isNotEmpty) sub.feedTitle,
      if (sub.lastFetchedAt != null) 'coletado ${relativeTime(sub.lastFetchedAt!)}',
    ].join(' · ');
    return ListTile(
      leading: CircleAvatar(
        child: Text(sub.title.isEmpty ? '?' : sub.title[0].toUpperCase()),
      ),
      title: Text(sub.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: sub.error != null
          ? Text(
              'Com problema: ${sub.error}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: theme.colorScheme.error),
            )
          : details.isEmpty
          ? null
          : Text(details, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (sub.unread > 0 && onOpen != null) Badge.count(count: sub.unread),
          IconButton(
            tooltip: 'Opções de ${sub.title}',
            onPressed: () => editSubscription(context, ref, sub),
            icon: const Icon(Icons.more_vert),
          ),
        ],
      ),
      onTap: () => onOpen == null ? editSubscription(context, ref, sub) : onOpen!(sub),
    );
  }
}
