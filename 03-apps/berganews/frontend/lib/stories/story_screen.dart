import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/format.dart';
import '../core/http.dart';
import '../core/widgets.dart';
import '../data/api.dart';
import '../data/models.dart';
import '../reader/reader_screen.dart';

Future<void> openStory(BuildContext context, int id) => Navigator.of(
  context,
).push(MaterialPageRoute<void>(builder: (_) => StoryScreen(storyId: id)));

/// Aba "Histórias": a mesma notícia em vários veículos, a mais recente
/// primeiro.
class StoriesTab extends ConsumerStatefulWidget {
  const StoriesTab({super.key});

  @override
  ConsumerState<StoriesTab> createState() => StoriesTabState();
}

class StoriesTabState extends ConsumerState<StoriesTab> {
  final _scroll = ScrollController();
  final _items = <StoryItem>[];
  String? _cursor;
  bool _loading = false;
  bool _done = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 600) {
        _loadMore();
      }
    });
    reload();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
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
      final page = await ref.read(apiProvider).stories(cursor: _cursor);
      if (!mounted) return;
      setState(() {
        _items.addAll(page.items);
        _cursor = page.nextCursor;
        _done = page.nextCursor == null;
      });
    } on Object catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
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
          children: const [
            SizedBox(height: 80),
            MessageView(
              icon: Icons.layers_outlined,
              title: 'Nenhuma história ainda',
              message:
                  'Quando a mesma notícia sair em dois veículos ou mais, ela aparece aqui, '
                  'com a linha do tempo de quem contou o quê.',
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
            return _done
                ? const SizedBox(height: 48)
                : const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  );
          }
          return StoryTile(story: _items[i]);
        },
      ),
    );
  }
}

class StoryTile extends StatelessWidget {
  const StoryTile({super.key, required this.story});

  final StoryItem story;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final names = story.sources.map((s) => s.title).take(4).join(', ');
    final more = story.sources.length > 4 ? ' e mais ${story.sources.length - 4}' : '';
    return InkWell(
      onTap: () => openStory(context, story.id),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${plural(story.sourceCount, 'veículo', 'veículos')} · '
                    '${relativeTime(story.lastPublishedAt)}',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.tertiary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    story.title,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: story.unread > 0 ? FontWeight.w600 : FontWeight.w400,
                      height: 1.25,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$names$more',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
                ],
              ),
            ),
            if (story.image != null) ...[
              const SizedBox(width: 12),
              ServerImage(story.image!, width: 96, height: 72),
            ],
          ],
        ),
      ),
    );
  }
}

/// Tela da história: todos os veículos, em ordem de publicação.
class StoryScreen extends ConsumerStatefulWidget {
  const StoryScreen({super.key, required this.storyId});

  final int storyId;

  @override
  ConsumerState<StoryScreen> createState() => _StoryScreenState();
}

class _StoryScreenState extends ConsumerState<StoryScreen> {
  Story? _story;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final story = await ref.read(apiProvider).story(widget.storyId);
      if (mounted) setState(() => _story = story);
    } on Object catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _split(TimelineArticle article) async {
    final ok = await confirm(
      context,
      title: 'Não é a mesma notícia?',
      message:
          '"${article.title}" sai desta história e vira uma história própria. '
          'Isso vale para todos da casa e ajuda a calibrar o agrupamento.',
      ok: 'Separar',
    );
    if (!ok || !mounted) return;
    try {
      await ref.read(apiProvider).splitStory(widget.storyId, [article.id]);
      if (!mounted) return;
      toast(context, 'Separada');
      await _load();
    } on Object catch (e) {
      if (mounted) toast(context, describeError(e));
    }
  }

  Future<void> _merge() async {
    final api = ref.read(apiProvider);
    ResultPage<StoryItem> page;
    try {
      page = await api.stories(days: 7);
    } on Object catch (e) {
      if (mounted) toast(context, describeError(e));
      return;
    }
    if (!mounted) return;
    final others = page.items.where((s) => s.id != widget.storyId).toList();
    final chosen = await showModalBottomSheet<StoryItem>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.7,
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text('Juntar com qual história? (é a mesma notícia)'),
              ),
              Expanded(
                child: others.isEmpty
                    ? const MessageView(
                        icon: Icons.layers_outlined,
                        title: 'Nenhuma outra história recente',
                      )
                    : ListView.builder(
                        itemCount: others.length,
                        itemBuilder: (context, i) => ListTile(
                          title: Text(
                            others[i].title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '${plural(others[i].sourceCount, 'veículo', 'veículos')} · '
                            '${relativeTime(others[i].lastPublishedAt)}',
                          ),
                          onTap: () => Navigator.pop(context, others[i]),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    try {
      await api.mergeStories(widget.storyId, chosen.id);
      if (!mounted) return;
      toast(context, 'Histórias juntadas');
      await _load();
    } on Object catch (e) {
      if (mounted) toast(context, describeError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final story = _story;
    return Scaffold(
      appBar: AppBar(
        title: const Text('História'),
        actions: [
          if (story != null)
            IconButton(
              tooltip: 'Juntar com outra história',
              onPressed: _merge,
              icon: const Icon(Icons.call_merge),
            ),
        ],
      ),
      body: _error != null
          ? ErrorView(_error!, onRetry: _load)
          : story == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(onRefresh: _load, child: _timeline(context, story)),
    );
  }

  Widget _timeline(BuildContext context, Story story) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final followed = story.articles.where((a) => a.followed).length;
    return ListView(
      padding: const EdgeInsets.only(bottom: 48),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
          child: Text(
            story.title,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
              height: 1.25,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Text(
            '${plural(story.sourceCount, 'veículo', 'veículos')} · '
            '${plural(story.articles.length, 'matéria', 'matérias')}'
            '${followed < story.articles.length ? ' · ${story.articles.length - followed} de veículos que você não assina' : ''}',
            style: theme.textTheme.bodyMedium?.copyWith(color: muted),
          ),
        ),
        for (var i = 0; i < story.articles.length; i++)
          _TimelineEntry(
            article: story.articles[i],
            first: i == 0,
            last: i == story.articles.length - 1,
            onSplit: story.articles.length > 1 ? () => _split(story.articles[i]) : null,
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
          child: Text(
            'O resumo da história chega numa próxima versão, gerado de madrugada pela IA local.',
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ),
      ],
    );
  }
}

class _TimelineEntry extends StatelessWidget {
  const _TimelineEntry({
    required this.article,
    required this.first,
    required this.last,
    this.onSplit,
  });

  final TimelineArticle article;
  final bool first;
  final bool last;
  final VoidCallback? onSplit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final line = theme.colorScheme.outlineVariant;
    final dot = article.followed ? theme.colorScheme.primary : theme.colorScheme.outline;
    final muted = theme.colorScheme.onSurfaceVariant;
    return InkWell(
      onTap: () => openArticleId(context, article.id),
      onLongPress: onSplit,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 40,
              child: Column(
                children: [
                  Expanded(
                    child: Container(width: 2, color: first ? Colors.transparent : line),
                  ),
                  Icon(Icons.circle, size: 12, color: dot),
                  Expanded(
                    flex: 4,
                    child: Container(width: 2, color: last ? Colors.transparent : line),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 10, 16, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      [
                        shortDateTime(article.publishedAt),
                        article.feedTitle,
                        if (!article.followed) 'não assinado',
                        if (article.duplicate) 'republicação',
                        if (article.language != null && article.language != 'pt')
                          languageName(article.language),
                      ].join(' · '),
                      style: theme.textTheme.labelMedium?.copyWith(color: muted),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      article.title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: article.read ? FontWeight.w400 : FontWeight.w600,
                      ),
                    ),
                    if (article.summary != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        article.summary!,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(color: muted),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (onSplit != null)
              IconButton(
                tooltip: 'Não é a mesma notícia',
                onPressed: onSplit,
                icon: const Icon(Icons.call_split, size: 20),
              ),
          ],
        ),
      ),
    );
  }
}
