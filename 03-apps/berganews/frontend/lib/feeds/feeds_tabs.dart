import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../articles/article_list.dart';
import '../core/http.dart';
import '../core/widgets.dart';
import '../data/api.dart';
import '../data/models.dart';
import 'manage.dart';

final subscriptionsProvider = FutureProvider.autoDispose<List<Subscription>>(
  (ref) => ref.watch(apiProvider).subscriptions(),
);

final foldersProvider = FutureProvider.autoDispose<List<Folder>>(
  (ref) => ref.watch(apiProvider).folders(),
);

/// Abre os artigos de um veículo ou de uma pasta.
Future<void> openFeed(
  BuildContext context, {
  required String title,
  int? feedId,
  int? folderId,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) =>
        FeedScreen(title: title, feedId: feedId, folderId: folderId),
  ),
);

/// Aba "Veículos": os veículos por pasta, com o número de não lidas; o menu
/// de cada um renomeia e muda de pasta, o de cada pasta renomeia e apaga.
class SourcesTab extends StatelessWidget {
  const SourcesTab({super.key});

  @override
  Widget build(BuildContext context) => SubscriptionsList(
    onOpen: (s) => openFeed(context, title: s.title, feedId: s.feedId),
  );
}

/// Aba "Pastas".
class FoldersTab extends ConsumerWidget {
  const FoldersTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final folders = ref.watch(foldersProvider);
    return folders.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) =>
          ErrorView(e, onRetry: () => ref.invalidate(foldersProvider)),
      data: (list) {
        if (list.isEmpty) {
          return const MessageView(
            icon: Icons.folder_outlined,
            title: 'Nenhuma pasta',
            message:
                'Crie pastas em Ajustes → Pastas e ponha os veículos nelas '
                '(ex.: Brasil, Mundo, Tecnologia).',
          );
        }
        return RefreshIndicator(
          onRefresh: () => ref.refresh(foldersProvider.future),
          child: ListView.builder(
            itemCount: list.length,
            itemBuilder: (context, i) {
              final f = list[i];
              return ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(f.name),
                trailing: f.unread > 0 ? Badge.count(count: f.unread) : null,
                onTap: () => openFeed(context, title: f.name, folderId: f.id),
              );
            },
          ),
        );
      },
    );
  }
}

/// Artigos de um veículo ou de uma pasta, com "só não lidas" e "marcar
/// tudo como lido".
class FeedScreen extends ConsumerStatefulWidget {
  const FeedScreen({super.key, required this.title, this.feedId, this.folderId});

  final String title;
  final int? feedId;
  final int? folderId;

  @override
  ConsumerState<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends ConsumerState<FeedScreen> {
  final _list = GlobalKey<ArticleListState>();
  bool _unread = false;

  Future<void> _markAll() async {
    final ok = await confirm(
      context,
      title: 'Marcar tudo como lido?',
      ok: 'Marcar',
    );
    if (!ok || !mounted) return;
    try {
      await ref
          .read(apiProvider)
          .markRead(
            feedId: widget.feedId,
            folderId: widget.folderId,
            before: DateTime.now(),
          );
      ref.invalidate(subscriptionsProvider);
      ref.invalidate(foldersProvider);
      await _list.currentState?.reload();
    } on Object catch (e) {
      if (mounted) toast(context, describeError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            tooltip: _unread ? 'Mostrar todas' : 'Só não lidas',
            isSelected: _unread,
            onPressed: () => setState(() => _unread = !_unread),
            icon: const Icon(Icons.filter_list),
          ),
          if (widget.feedId != null)
            IconButton(
              tooltip: 'Atualizar o feed agora',
              onPressed: () async {
                await ref.read(apiProvider).refreshFeed(widget.feedId!);
                if (context.mounted) {
                  toast(context, 'Buscando matérias novas…');
                }
              },
              icon: const Icon(Icons.sync),
            ),
          IconButton(
            tooltip: 'Marcar tudo como lido',
            onPressed: _markAll,
            icon: const Icon(Icons.done_all),
          ),
        ],
      ),
      body: ArticleList(
        key: _list,
        query: ArticleQuery(
          view: _unread ? 'unread' : 'all',
          feedId: widget.feedId,
          folderId: widget.folderId,
        ),
        emptyTitle: _unread ? 'Tudo lido' : 'Nenhuma matéria ainda',
        emptyMessage: _unread
            ? null
            : 'A primeira coleta pode levar alguns minutos.',
      ),
    );
  }
}
