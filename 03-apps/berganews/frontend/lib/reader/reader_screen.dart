import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../articles/article_list.dart';
import '../auth/session.dart';
import '../core/format.dart';
import '../core/http.dart';
import '../core/prefs.dart';
import '../core/theme.dart';
import '../core/widgets.dart';
import '../data/api.dart';
import '../data/models.dart';
import '../stories/story_screen.dart';
import 'video_card.dart';

/// Abre o artigo no leitor (ou no site, se a pessoa preferir).
Future<void> openArticle(
  BuildContext context,
  WidgetRef ref,
  ArticleItem item,
) async {
  final prefs = ref.read(prefsProvider).value ?? Prefs.defaults;
  if (prefs.openOriginal) {
    await openExternal(item.url);
    if (prefs.markReadOnOpen && !item.read) {
      ref
          .read(articleMarksProvider.notifier)
          .set(item.id, read: true, saved: item.saved);
      unawaited(ref.read(apiProvider).setState(item.id, read: true));
    }
    return;
  }
  await openArticleId(context, item.id);
}

Future<void> openArticleId(BuildContext context, int id) => Navigator.of(
  context,
).push(MaterialPageRoute<void>(builder: (_) => ReaderScreen(articleId: id)));

Future<void> openExternal(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return;
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

class ReaderScreen extends ConsumerStatefulWidget {
  const ReaderScreen({super.key, required this.articleId});

  final int articleId;

  @override
  ConsumerState<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends ConsumerState<ReaderScreen> {
  Article? _article;
  Object? _error;
  bool _saved = false;

  // Tradução: a pessoa alterna entre o original e a tradução.
  TranslationState? _translation;
  bool _showTranslation = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final article = await ref.read(apiProvider).article(widget.articleId);
      if (!mounted) return;
      final prefs = ref.read(prefsProvider).value ?? Prefs.defaults;
      ref
          .read(articleMarksProvider.notifier)
          .set(
            article.item.id,
            read: article.item.read || prefs.markReadOnOpen,
            saved: article.item.saved,
          );
      setState(() {
        _article = article;
        _saved = article.item.saved;
      });
    } on Object catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _toggleSaved() async {
    final article = _article;
    if (article == null) return;
    final saved = !_saved;
    setState(() => _saved = saved);
    ref
        .read(articleMarksProvider.notifier)
        .set(article.item.id, read: true, saved: saved);
    try {
      await ref.read(apiProvider).setState(article.item.id, saved: saved);
      if (mounted) toast(context, saved ? 'Salvo' : 'Tirado dos salvos');
    } on Object catch (e) {
      if (mounted) {
        setState(() => _saved = !saved);
        toast(context, describeError(e));
      }
    }
  }

  // ── Tradução ────────────────────────────────────────────────────────

  Future<void> _translate() async {
    final article = _article;
    final lang = article?.translateTo;
    if (article == null || lang == null) return;
    if (_translation?.ready ?? false) {
      setState(() => _showTranslation = !_showTranslation);
      return;
    }
    if (_poll != null) return; // já traduzindo
    final api = ref.read(apiProvider);
    try {
      final existing = await api.translation(article.item.id, lang);
      final TranslationState current = existing == null || existing.failed
          ? await api.requestTranslation(article.item.id, lang)
          : existing;
      if (!mounted) return;
      setState(() {
        _translation = current;
        _showTranslation = current.ready;
      });
      if (!current.ready) _startPolling(article.item.id, lang);
    } on Object catch (e) {
      if (mounted) toast(context, describeError(e));
    }
  }

  void _startPolling(int id, String lang) {
    _poll = Timer.periodic(const Duration(seconds: 2), (timer) async {
      try {
        final current = await ref.read(apiProvider).translation(id, lang);
        if (!mounted) {
          timer.cancel();
          return;
        }
        if (current == null) return;
        setState(() {
          _translation = current;
          if (current.ready) _showTranslation = true;
        });
        if (current.ready || current.failed) {
          timer.cancel();
          _poll = null;
          if (current.failed && mounted) {
            toast(context, current.error ?? 'A tradução falhou.');
          }
        }
      } on Object {
        // Rede oscilou: tenta na próxima volta.
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final article = _article;
    return Scaffold(
      appBar: AppBar(
        actions: article == null
            ? null
            : [
                if (article.translateTo != null)
                  IconButton(
                    tooltip: _showTranslation
                        ? 'Ver o original'
                        : 'Traduzir para o ${languageName(article.translateTo)}',
                    isSelected: _showTranslation,
                    onPressed: _translate,
                    icon: const Icon(Icons.translate),
                  ),
                IconButton(
                  tooltip: _saved ? 'Tirar dos salvos' : 'Salvar',
                  onPressed: _toggleSaved,
                  icon: Icon(_saved ? Icons.bookmark : Icons.bookmark_border),
                ),
                IconButton(
                  tooltip: 'Abrir no site',
                  onPressed: () => openExternal(article.item.url),
                  icon: const Icon(Icons.open_in_browser),
                ),
                IconButton(
                  tooltip: 'Compartilhar',
                  onPressed: () => SharePlus.instance.share(
                    ShareParams(
                      text: '${article.item.title}\n${article.item.url}',
                    ),
                  ),
                  icon: const Icon(Icons.share_outlined),
                ),
              ],
      ),
      body: _error != null
          ? ErrorView(_error!, onRetry: _load)
          : article == null
          ? const Center(child: CircularProgressIndicator())
          : _body(context, article),
    );
  }

  Widget _body(BuildContext context, Article article) {
    final theme = Theme.of(context);
    final prefs = ref.watch(prefsProvider).value ?? Prefs.defaults;
    final server = ref.watch(sessionProvider.select((s) => s.server)) ?? '';
    final item = article.item;
    final translated = _showTranslation ? _translation?.translation : null;
    final title = translated?.title ?? item.title;
    final html = translated?.contentHtml ?? article.contentHtml;
    final muted = theme.colorScheme.onSurfaceVariant;
    final progress = _translation != null && !_translation!.ready && !_translation!.failed;
    final bodyStyle = theme.textTheme.bodyLarge?.copyWith(
      fontSize: 17 * prefs.textScale,
      height: 1.6,
    );

    return Column(
      children: [
        if (progress)
          LinearProgressIndicator(
            value: _translation!.total > 0
                ? _translation!.done / _translation!.total
                : null,
          ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 48),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: readerWidth),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      [
                        item.feeds,
                        relativeTime(item.publishedAt),
                        if (item.author != null) item.author!,
                      ].join(' · '),
                      style: theme.textTheme.labelLarge?.copyWith(color: muted),
                    ),
                    const SizedBox(height: 8),
                    SelectableText(
                      title,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        fontSize:
                            (theme.textTheme.headlineSmall?.fontSize ?? 24) *
                            prefs.textScale,
                        height: 1.25,
                      ),
                    ),
                    if (progress) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Traduzindo para o ${languageName(article.translateTo)}… '
                        '${_translation!.total > 0 ? '${_translation!.done} de ${_translation!.total}' : 'na fila'}',
                        style: theme.textTheme.bodySmall?.copyWith(color: muted),
                      ),
                    ],
                    if (translated != null) ...[
                      const SizedBox(height: 8),
                      ActionChip(
                        avatar: const Icon(Icons.translate, size: 16),
                        label: Text(
                          'Traduzido do ${languageName(item.language)} · ver o original',
                        ),
                        onPressed: () => setState(() => _showTranslation = false),
                      ),
                    ],
                    if (item.storyId != null && item.storySources >= 2) ...[
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.layers_outlined),
                        label: Text(
                          'Como ${plural(item.storySources, 'veículo contou', 'veículos contaram')}',
                        ),
                        onPressed: () => openStory(context, item.storyId!),
                      ),
                    ],
                    const SizedBox(height: 16),
                    if (item.image != null &&
                        (html == null || !html.contains('<img')))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: ServerImage(item.image!, fit: BoxFit.contain),
                      ),
                    if (html != null && html.isNotEmpty)
                      HtmlWidget(
                        _absoluteImages(html, server),
                        textStyle: bodyStyle,
                        customWidgetBuilder: (element) => videoCardFor(element, openExternal),
                        onTapUrl: (url) async {
                          await openExternal(url);
                          return true;
                        },
                      )
                    else if (item.summary != null)
                      Text(item.summary!, style: bodyStyle),
                    if (article.contentStatus != 'ok') ...[
                      const SizedBox(height: 24),
                      Card.outlined(
                        child: ListTile(
                          leading: const Icon(Icons.lock_outline),
                          title: const Text('Só o trecho'),
                          subtitle: const Text(
                            'O texto completo não veio (paywall ou página difícil de ler). '
                            'Abra no site para ler tudo.',
                          ),
                          trailing: const Icon(Icons.open_in_new),
                          onTap: () => openExternal(item.url),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// As imagens vêm como `/api/img?...`: fora da web precisam do servidor.
  static String _absoluteImages(String html, String server) => html
      .replaceAll('src="/api/img', 'src="${absoluteUrl(server, '/api/img')}');
}
