import 'package:berganews/auth/login_screen.dart';
import 'package:berganews/auth/session.dart';
import 'package:berganews/core/format.dart';
import 'package:berganews/core/http.dart';
import 'package:berganews/core/storage.dart';
import 'package:berganews/data/api.dart';
import 'package:berganews/data/models.dart';
import 'package:berganews/reader/video_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;

void main() {
  group('formatação', () {
    final now = DateTime(2026, 11, 6, 15, 0);

    test('tempo relativo', () {
      expect(relativeTime(now.subtract(const Duration(seconds: 20)), now: now), 'agora');
      expect(relativeTime(now.subtract(const Duration(minutes: 5)), now: now), 'há 5 min');
      expect(relativeTime(now.subtract(const Duration(hours: 3)), now: now), 'há 3 h');
      expect(relativeTime(DateTime(2026, 11, 5, 14, 5), now: now), 'ontem, 14:05');
      expect(relativeTime(DateTime(2026, 10, 12, 9, 30), now: now), '12 out, 09:30');
      expect(relativeTime(DateTime(2025, 10, 12, 9, 30), now: now), '12 out 2025');
    });

    test('plural e idioma', () {
      expect(plural(1, 'veículo', 'veículos'), '1 veículo');
      expect(plural(3, 'veículo', 'veículos'), '3 veículos');
      expect(languageName('en'), 'inglês');
    });
  });

  group('endereço do servidor', () {
    test('normaliza', () {
      expect(normalizeServer('news.example.com/'), 'https://news.example.com');
      expect(normalizeServer('http://10.0.0.2:8000'), 'http://10.0.0.2:8000');
      expect(normalizeServer('   '), isNull);
      expect(normalizeServer('ftp://x'), isNull);
    });

    test('imagem do servidor vira endereço completo', () {
      expect(
        absoluteUrl('https://news.example.com', '/api/img?u=x&s=y'),
        'https://news.example.com/api/img?u=x&s=y',
      );
      expect(absoluteUrl('https://a', 'https://b/c.png'), 'https://b/c.png');
    });
  });

  group('modelos', () {
    test('artigo', () {
      final a = Article.fromJson({
        'id': 7,
        'feed_id': 2,
        'feed_title': 'Folha',
        'title': 'Senado aprova',
        'summary': 'Trecho',
        'image': '/api/img?u=a&s=b',
        'url': 'https://folha.example.com/1',
        'author': null,
        'language': 'pt',
        'published_at': '2026-11-06T12:00:00+00:00',
        'read': false,
        'saved': true,
        'full_text': true,
        'story_id': 3,
        'story_sources': 4,
        'content_html': '<p>Oi</p>',
        'content_status': 'ok',
        'translate_to': 'en',
        'translations': ['en'],
      });
      expect(a.item.feedTitle, 'Folha');
      expect(a.item.saved, isTrue);
      expect(a.item.storySources, 4);
      expect(a.translateTo, 'en');
      expect(a.translations, ['en']);
      expect(a.item.copyWith(read: true).read, isTrue);
    });

    test('preferências: abas, ida e volta', () {
      final p = Prefs.fromJson({
        'tabs': [
          {'id': 'stories', 'enabled': true, 'available': true},
          {'id': 'all', 'enabled': false},
          {'id': 'nao-existe', 'enabled': true},
          {'id': 'saved', 'enabled': true, 'available': false},
        ],
        'theme': 'dark',
        'text_scale': 1.2,
      });
      expect(p.tabs.map((t) => t.id), [TabId.stories, TabId.all, TabId.saved]);
      expect(p.enabledTabs, [TabId.stories]);
      expect(p.theme, 'dark');
      final again = Prefs.fromJson(p.toJson());
      expect(again.tabs.map((t) => t.id), p.tabs.map((t) => t.id));
      expect(again.textScale, 1.2);
    });

    test('história', () {
      final s = Story.fromJson({
        'id': 1,
        'title': 'Reforma',
        'source_count': 3,
        'articles': [
          {
            'id': 9,
            'feed_title': 'BBC',
            'followed': false,
            'title': 'Tax reform',
            'published_at': '2026-11-06T12:00:00Z',
            'read': false,
            'manual': false,
            'similarity': 0.91,
            'language': 'en',
          },
        ],
      });
      expect(s.articles.single.followed, isFalse);
      expect(s.articles.single.similarity, closeTo(0.91, 1e-9));
    });

    test('filtro de artigos compara por valor', () {
      expect(const ArticleQuery(feedId: 1), const ArticleQuery(feedId: 1));
      expect(const ArticleQuery(feedId: 1) == const ArticleQuery(feedId: 2), isFalse);
    });
  });

  group('sessão', () {
    test('sem tokens começa deslogado; com tokens, logado', () async {
      final empty = SessionStorage(MemoryKeyValueStore());
      expect((await empty.load(defaultServer: 'https://x')).status, SessionStatus.loggedOut);

      final store = MemoryKeyValueStore();
      final storage = SessionStorage(store);
      await storage.saveLogin(
        'https://news.example.com',
        const User(id: 'u1', username: 'lucas', name: 'Lucas', isAdmin: true),
        const Tokens(access: 'a', refresh: 'r'),
      );
      final loaded = await SessionStorage(store).load();
      expect(loaded.status, SessionStatus.loggedIn);
      expect(loaded.user?.isAdmin, isTrue);
      expect(loaded.server, 'https://news.example.com');
    });
  });

  testWidgets('tela de login mostra o botão do Authentik', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          keyValueStoreProvider.overrideWithValue(MemoryKeyValueStore()),
          initialSessionProvider.overrideWithValue(
            const SessionState(status: SessionStatus.loggedOut),
          ),
        ],
        child: const MaterialApp(home: LoginScreen()),
      ),
    );
    expect(find.text('Entrar com o Authentik'), findsOneWidget);
    expect(find.text('Servidor'), findsOneWidget);
  });

  test('cartão de vídeo sai do link marcado', () {
    final doc = html_parser.parseFragment(
      '<a href="https://globoplay.globo.com/v/1/" title="berganews:video">'
      '<img src="/api/img?u=x" alt="Conheça o navio"></a><a href="https://x">link</a>',
    );
    final links = doc.querySelectorAll('a');
    String? opened;
    final card = videoCardFor(links[0], (url) => opened = url) as VideoCard;
    expect(card.label, 'Conheça o navio');
    expect(card.thumbnail, '/api/img?u=x');
    card.onTap!();
    expect(opened, 'https://globoplay.globo.com/v/1/');
    expect(videoCardFor(links[1], (_) {}), isNull);
  });
}
