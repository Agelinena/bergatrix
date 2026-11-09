import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/format.dart';
import '../core/widgets.dart';
import '../data/api.dart';
import '../data/models.dart';
import '../reader/reader_screen.dart';

/// Lido e salvo mudados nesta sessão do app (no leitor ou na lista): as
/// listas já abertas mostram na hora, sem recarregar.
class ArticleMarks extends Notifier<Map<int, ({bool read, bool saved})>> {
  @override
  Map<int, ({bool read, bool saved})> build() => const {};

  void set(int id, {required bool read, required bool saved}) {
    state = {...state, id: (read: read, saved: saved)};
  }

  ArticleItem apply(ArticleItem item) {
    final mark = state[item.id];
    return mark == null
        ? item
        : item.copyWith(read: mark.read, saved: mark.saved);
  }
}

final articleMarksProvider =
    NotifierProvider<ArticleMarks, Map<int, ({bool read, bool saved})>>(
      ArticleMarks.new,
    );

/// Lista paginada de artigos (as abas Todas e Salvos, um veículo, uma pasta,
/// a busca).
class ArticleList extends ConsumerStatefulWidget {
  const ArticleList({
    super.key,
    required this.query,
    this.emptyTitle = 'Nada por aqui',
    this.emptyMessage,
  });

  final ArticleQuery query;
  final String emptyTitle;
  final String? emptyMessage;

  @override
  ConsumerState<ArticleList> createState() => ArticleListState();
}

class ArticleListState extends ConsumerState<ArticleList> {
  final _scroll = ScrollController();
  final _items = <ArticleItem>[];
  String? _cursor;
  bool _loading = false;
  bool _done = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    reload();
  }

  @override
  void didUpdateWidget(ArticleList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query) reload();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 800) {
      _loadMore();
    }
  }

  Future<void> reload() async {
    setState(() {
      _items.clear();
      _cursor = null;
      _done = false;
      _error = null;
    });
    await _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading || _done) return;
    setState(() => _loading = true);
    try {
      final page = await ref
          .read(apiProvider)
          .articles(widget.query, cursor: _cursor);
      if (!mounted) return;
      setState(() {
        _items.addAll(page.items);
        _cursor = page.nextCursor;
        _done = page.nextCursor == null;
        _error = null;
      });
    } on Object catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final marks = ref.watch(articleMarksProvider.notifier);
    ref.watch(articleMarksProvider);
    if (_items.isEmpty && _error != null) {
      return ErrorView(_error!, onRetry: reload);
    }
    if (_items.isEmpty && _loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_items.isEmpty) {
      return RefreshIndicator(
        onRefresh: reload,
        child: ListView(
          children: [
            const SizedBox(height: 80),
            MessageView(
              icon: Icons.inbox_outlined,
              title: widget.emptyTitle,
              message: widget.emptyMessage,
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: reload,
      child: ListView.separated(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: _items.length + 1,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, i) {
          if (i == _items.length) {
            if (_done) return const SizedBox(height: 48);
            if (_error != null) {
              return TextButton(
                onPressed: _loadMore,
                child: const Text('Falhou. Tentar de novo'),
              );
            }
            return const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          return ArticleTile(item: marks.apply(_items[i]));
        },
      ),
    );
  }
}

class ArticleTile extends ConsumerWidget {
  const ArticleTile({super.key, required this.item, this.showSource = true});

  final ArticleItem item;
  final bool showSource;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final titleStyle = theme.textTheme.titleMedium?.copyWith(
      fontWeight: item.read ? FontWeight.w400 : FontWeight.w600,
      color: item.read ? muted : null,
      height: 1.25,
    );
    return InkWell(
      onTap: () => openArticle(context, ref, item),
      onLongPress: () => _menu(context, ref),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (!item.read)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: Icon(
                            Icons.circle,
                            size: 8,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      Flexible(
                        child: Text(
                          [
                            if (showSource) item.feeds,
                            relativeTime(item.publishedAt),
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: muted,
                          ),
                        ),
                      ),
                      if (item.saved)
                        Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: Icon(
                            Icons.bookmark,
                            size: 14,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    item.title,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: titleStyle,
                  ),
                  if (item.summary != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      item.summary!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                    ),
                  ],
                  if (item.storySources >= 2) ...[
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Icon(
                          Icons.layers_outlined,
                          size: 14,
                          color: theme.colorScheme.tertiary,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'Em ${plural(item.storySources, 'veículo', 'veículos')}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.tertiary,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            if (item.image != null) ...[
              const SizedBox(width: 12),
              ServerImage(item.image!, width: 96, height: 72),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _menu(BuildContext context, WidgetRef ref) async {
    final api = ref.read(apiProvider);
    final marks = ref.read(articleMarksProvider.notifier);
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                item.read ? Icons.mark_email_unread_outlined : Icons.done,
              ),
              title: Text(
                item.read ? 'Marcar como não lida' : 'Marcar como lida',
              ),
              onTap: () => Navigator.pop(context, 'read'),
            ),
            ListTile(
              leading: Icon(
                item.saved ? Icons.bookmark_remove_outlined : Icons.bookmark_add_outlined,
              ),
              title: Text(item.saved ? 'Tirar dos salvos' : 'Salvar'),
              onTap: () => Navigator.pop(context, 'save'),
            ),
          ],
        ),
      ),
    );
    if (action == null) return;
    final read = action == 'read' ? !item.read : item.read;
    final saved = action == 'save' ? !item.saved : item.saved;
    marks.set(item.id, read: read, saved: saved);
    try {
      await api.setState(
        item.id,
        read: action == 'read' ? read : null,
        saved: action == 'save' ? saved : null,
      );
    } on Object catch (e) {
      marks.set(item.id, read: item.read, saved: item.saved);
      if (context.mounted) toast(context, 'Não deu: $e');
    }
  }
}
