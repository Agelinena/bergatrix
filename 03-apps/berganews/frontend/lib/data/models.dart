// Modelos da API do Berganews (backend/app/*/routes.py), lidos à mão do JSON.

typedef Json = Map<String, dynamic>;

DateTime _date(Object? value) =>
    DateTime.tryParse(value as String? ?? '')?.toLocal() ?? DateTime.now();

class User {
  const User({
    required this.id,
    required this.username,
    required this.name,
    required this.isAdmin,
    this.email,
  });

  final String id;
  final String username;
  final String name;
  final String? email;
  final bool isAdmin;

  factory User.fromJson(Json j) => User(
    id: j['id'] as String,
    username: j['username'] as String,
    name: j['name'] as String,
    email: j['email'] as String?,
    isAdmin: j['is_admin'] as bool? ?? false,
  );
}

class Tokens {
  const Tokens({required this.access, required this.refresh});

  final String access;
  final String refresh;
}

class AuthConfig {
  const AuthConfig({required this.oidcEnabled, required this.accountUrl});

  final bool oidcEnabled;
  final String accountUrl;

  factory AuthConfig.fromJson(Json j) => AuthConfig(
    oidcEnabled: j['oidc_enabled'] as bool? ?? false,
    accountUrl: j['account_url'] as String? ?? '',
  );
}

// ── Preferências ──────────────────────────────────────────────────────

/// Abas da tela inicial (ids iguais aos do servidor, app/prefs/routes.py).
enum TabId {
  all('Todas'),
  sources('Veículos'),
  folders('Pastas'),
  stories('Histórias'),
  saved('Salvos');

  const TabId(this.label);

  final String label;

  static TabId? parse(String value) {
    for (final t in TabId.values) {
      if (t.name == value) return t;
    }
    return null;
  }
}

class TabPref {
  const TabPref({
    required this.id,
    required this.enabled,
    this.available = true,
  });

  final TabId id;
  final bool enabled;
  final bool available;

  TabPref copyWith({bool? enabled}) =>
      TabPref(id: id, enabled: enabled ?? this.enabled, available: available);

  Json toJson() => {'id': id.name, 'enabled': enabled};
}

class Prefs {
  const Prefs({
    required this.tabs,
    this.language = 'pt',
    this.theme = 'system',
    this.textScale = 1.0,
    this.openOriginal = false,
    this.markReadOnOpen = true,
  });

  final List<TabPref> tabs;
  final String language;
  final String theme; // system | light | dark
  final double textScale;
  final bool openOriginal;
  final bool markReadOnOpen;

  static const defaults = Prefs(
    tabs: [
      TabPref(id: TabId.all, enabled: true),
      TabPref(id: TabId.sources, enabled: true),
      TabPref(id: TabId.folders, enabled: true),
      TabPref(id: TabId.stories, enabled: true),
      TabPref(id: TabId.saved, enabled: true),
    ],
  );

  List<TabId> get enabledTabs => [
    for (final t in tabs)
      if (t.enabled && t.available) t.id,
  ];

  factory Prefs.fromJson(Json j) {
    final tabs = <TabPref>[];
    for (final raw in (j['tabs'] as List? ?? const [])) {
      final m = raw as Json;
      final id = TabId.parse(m['id'] as String? ?? '');
      if (id == null) continue;
      tabs.add(
        TabPref(
          id: id,
          enabled: m['enabled'] as bool? ?? true,
          available: m['available'] as bool? ?? true,
        ),
      );
    }
    return Prefs(
      tabs: tabs.isEmpty ? defaults.tabs : tabs,
      language: j['language'] as String? ?? 'pt',
      theme: j['theme'] as String? ?? 'system',
      textScale: (j['text_scale'] as num?)?.toDouble() ?? 1.0,
      openOriginal: j['open_original'] as bool? ?? false,
      markReadOnOpen: j['mark_read_on_open'] as bool? ?? true,
    );
  }

  Prefs copyWith({
    List<TabPref>? tabs,
    String? language,
    String? theme,
    double? textScale,
    bool? openOriginal,
    bool? markReadOnOpen,
  }) => Prefs(
    tabs: tabs ?? this.tabs,
    language: language ?? this.language,
    theme: theme ?? this.theme,
    textScale: textScale ?? this.textScale,
    openOriginal: openOriginal ?? this.openOriginal,
    markReadOnOpen: markReadOnOpen ?? this.markReadOnOpen,
  );

  Json toJson() => {
    'tabs': [for (final t in tabs) t.toJson()],
    'language': language,
    'theme': theme,
    'text_scale': textScale,
    'open_original': openOriginal,
    'mark_read_on_open': markReadOnOpen,
  };
}

// ── Feeds ─────────────────────────────────────────────────────────────

class Subscription {
  const Subscription({
    required this.feedId,
    required this.title,
    required this.feedTitle,
    required this.url,
    required this.unread,
    this.siteUrl,
    this.language,
    this.folderId,
    this.lastFetchedAt,
    this.error,
  });

  final int feedId;
  final String title;
  final String feedTitle;
  final String url;
  final String? siteUrl;
  final String? language;
  final int? folderId;
  final int unread;
  final DateTime? lastFetchedAt;
  final String? error;

  factory Subscription.fromJson(Json j) => Subscription(
    feedId: j['feed_id'] as int,
    title: j['title'] as String,
    feedTitle: j['feed_title'] as String? ?? '',
    url: j['url'] as String,
    siteUrl: j['site_url'] as String?,
    language: j['language'] as String?,
    folderId: j['folder_id'] as int?,
    unread: j['unread'] as int? ?? 0,
    lastFetchedAt: j['last_fetched_at'] == null
        ? null
        : _date(j['last_fetched_at']),
    error: j['error'] as String?,
  );
}

class Folder {
  const Folder({
    required this.id,
    required this.name,
    required this.position,
    required this.unread,
  });

  final int id;
  final String name;
  final int position;
  final int unread;

  factory Folder.fromJson(Json j) => Folder(
    id: j['id'] as int,
    name: j['name'] as String,
    position: j['position'] as int? ?? 0,
    unread: j['unread'] as int? ?? 0,
  );
}

class ImportResult {
  const ImportResult({
    required this.added,
    required this.already,
    required this.failed,
  });

  final int added;
  final int already;
  final List<String> failed;

  factory ImportResult.fromJson(Json j) => ImportResult(
    added: j['added'] as int? ?? 0,
    already: j['already'] as int? ?? 0,
    failed: [for (final f in (j['failed'] as List? ?? const [])) f as String],
  );
}

// ── Artigos ───────────────────────────────────────────────────────────

class ArticleItem {
  const ArticleItem({
    required this.id,
    required this.feedId,
    required this.feedTitle,
    required this.title,
    required this.url,
    required this.publishedAt,
    required this.read,
    required this.saved,
    required this.fullText,
    this.summary,
    this.image,
    this.author,
    this.language,
    this.storyId,
    this.storySources = 0,
    this.alsoIn = const [],
  });

  final int id;
  final int feedId;
  final String feedTitle;

  /// Outros feeds que publicaram exatamente esta matéria: ela aparece uma
  /// vez só, creditada a todos.
  final List<String> alsoIn;

  /// "G1 Tecnologia · G1 Economia".
  String get feeds => [feedTitle, ...alsoIn].join(' · ');
  final String title;
  final String? summary;
  final String? image;
  final String url;
  final String? author;
  final String? language;
  final DateTime publishedAt;
  final bool read;
  final bool saved;
  final bool fullText;
  final int? storyId;
  final int storySources;

  factory ArticleItem.fromJson(Json j) => ArticleItem(
    id: j['id'] as int,
    feedId: j['feed_id'] as int,
    feedTitle: j['feed_title'] as String? ?? '',
    title: j['title'] as String,
    summary: j['summary'] as String?,
    image: j['image'] as String?,
    url: j['url'] as String,
    author: j['author'] as String?,
    language: j['language'] as String?,
    publishedAt: _date(j['published_at']),
    read: j['read'] as bool? ?? false,
    saved: j['saved'] as bool? ?? false,
    fullText: j['full_text'] as bool? ?? false,
    storyId: j['story_id'] as int?,
    storySources: j['story_sources'] as int? ?? 0,
    alsoIn: [for (final f in (j['also_in'] as List? ?? const [])) f as String],
  );

  ArticleItem copyWith({bool? read, bool? saved}) => ArticleItem(
    id: id,
    feedId: feedId,
    feedTitle: feedTitle,
    title: title,
    summary: summary,
    image: image,
    url: url,
    author: author,
    language: language,
    publishedAt: publishedAt,
    read: read ?? this.read,
    saved: saved ?? this.saved,
    fullText: fullText,
    storyId: storyId,
    storySources: storySources,
    alsoIn: alsoIn,
  );
}

/// Uma página de resultados (o nome `Page` já é do Flutter).
class ResultPage<T> {
  const ResultPage(this.items, this.nextCursor);

  final List<T> items;
  final String? nextCursor;
}

class Article {
  const Article({
    required this.item,
    required this.translations,
    this.contentHtml,
    this.contentStatus,
    this.translateTo,
  });

  final ArticleItem item;
  final String? contentHtml;

  /// ok = texto completo; short = só o trecho (paywall); error/null.
  final String? contentStatus;
  final String? translateTo;
  final List<String> translations;

  factory Article.fromJson(Json j) => Article(
    item: ArticleItem.fromJson(j),
    contentHtml: j['content_html'] as String?,
    contentStatus: j['content_status'] as String?,
    translateTo: j['translate_to'] as String?,
    translations: [
      for (final t in (j['translations'] as List? ?? const [])) t as String,
    ],
  );
}

class Translation {
  const Translation({
    required this.lang,
    required this.title,
    required this.contentHtml,
  });

  final String lang;
  final String title;
  final String contentHtml;

  factory Translation.fromJson(Json j) => Translation(
    lang: j['lang'] as String,
    title: j['title'] as String,
    contentHtml: j['content_html'] as String,
  );
}

/// Tradução pronta ou em andamento.
class TranslationState {
  const TranslationState({
    this.translation,
    this.state = 'queued',
    this.done = 0,
    this.total = 0,
    this.error,
  });

  final Translation? translation;
  final String state; // queued | running | error | done
  final int done;
  final int total;
  final String? error;

  bool get ready => translation != null;
  bool get failed => state == 'error';

  factory TranslationState.fromJson(Json j) => TranslationState(
    state: j['state'] as String? ?? 'queued',
    done: j['done'] as int? ?? 0,
    total: j['total'] as int? ?? 0,
    error: j['error'] as String?,
  );
}

// ── Histórias ─────────────────────────────────────────────────────────

class StorySource {
  const StorySource({
    required this.feedId,
    required this.title,
    required this.followed,
  });

  final int feedId;
  final String title;
  final bool followed;

  factory StorySource.fromJson(Json j) => StorySource(
    feedId: j['feed_id'] as int,
    title: j['title'] as String,
    followed: j['followed'] as bool? ?? false,
  );
}

class StoryItem {
  const StoryItem({
    required this.id,
    required this.title,
    required this.firstPublishedAt,
    required this.lastPublishedAt,
    required this.articleCount,
    required this.sourceCount,
    required this.unread,
    required this.sources,
    this.image,
  });

  final int id;
  final String title;
  final DateTime firstPublishedAt;
  final DateTime lastPublishedAt;
  final int articleCount;
  final int sourceCount;
  final int unread;
  final String? image;
  final List<StorySource> sources;

  factory StoryItem.fromJson(Json j) => StoryItem(
    id: j['id'] as int,
    title: j['title'] as String,
    firstPublishedAt: _date(j['first_published_at']),
    lastPublishedAt: _date(j['last_published_at']),
    articleCount: j['article_count'] as int? ?? 0,
    sourceCount: j['source_count'] as int? ?? 0,
    unread: j['unread'] as int? ?? 0,
    image: j['image'] as String?,
    sources: [
      for (final s in (j['sources'] as List? ?? const []))
        StorySource.fromJson(s as Json),
    ],
  );
}

class TimelineArticle {
  const TimelineArticle({
    required this.id,
    required this.feedTitle,
    required this.followed,
    required this.title,
    required this.publishedAt,
    required this.read,
    required this.manual,
    this.summary,
    this.image,
    this.language,
    this.similarity,
    this.alsoIn = const [],
  });

  final int id;
  final String feedTitle;
  final bool followed;
  final String title;
  final String? summary;
  final String? image;
  final String? language;
  final DateTime publishedAt;
  final bool read;
  final bool manual;
  final double? similarity;

  /// Outros feeds que publicaram exatamente esta matéria (ela aparece uma
  /// vez só na linha do tempo, creditada a todos).
  final List<String> alsoIn;

  /// "G1 Tecnologia · G1 Economia".
  String get feeds => [feedTitle, ...alsoIn].join(' · ');

  factory TimelineArticle.fromJson(Json j) => TimelineArticle(
    id: j['id'] as int,
    feedTitle: j['feed_title'] as String? ?? '',
    followed: j['followed'] as bool? ?? false,
    title: j['title'] as String,
    summary: j['summary'] as String?,
    image: j['image'] as String?,
    language: j['language'] as String?,
    publishedAt: _date(j['published_at']),
    read: j['read'] as bool? ?? false,
    manual: j['manual'] as bool? ?? false,
    similarity: (j['similarity'] as num?)?.toDouble(),
    alsoIn: [for (final f in (j['also_in'] as List? ?? const [])) f as String],
  );
}

class Story {
  const Story({
    required this.id,
    required this.title,
    required this.sourceCount,
    required this.articles,
  });

  final int id;
  final String title;
  final int sourceCount;
  final List<TimelineArticle> articles;

  factory Story.fromJson(Json j) => Story(
    id: j['id'] as int,
    title: j['title'] as String,
    sourceCount: j['source_count'] as int? ?? 0,
    articles: [
      for (final a in (j['articles'] as List? ?? const []))
        TimelineArticle.fromJson(a as Json),
    ],
  );
}

// ── Admin ─────────────────────────────────────────────────────────────

class AdminUser {
  const AdminUser({
    required this.id,
    required this.name,
    required this.username,
    required this.isAdmin,
    required this.disabled,
    required this.subscriptions,
    required this.sessions,
    this.email,
    this.lastLoginAt,
  });

  final String id;
  final String name;
  final String username;
  final String? email;
  final bool isAdmin;
  final bool disabled;
  final int subscriptions;
  final int sessions;
  final DateTime? lastLoginAt;

  factory AdminUser.fromJson(Json j) => AdminUser(
    id: j['id'] as String,
    name: j['name'] as String,
    username: j['username'] as String,
    email: j['email'] as String?,
    isAdmin: j['is_admin'] as bool? ?? false,
    disabled: j['disabled'] as bool? ?? false,
    subscriptions: j['subscriptions'] as int? ?? 0,
    sessions: j['sessions'] as int? ?? 0,
    lastLoginAt: j['last_login_at'] == null ? null : _date(j['last_login_at']),
  );
}
