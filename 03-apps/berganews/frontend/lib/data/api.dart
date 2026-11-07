import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/session.dart';
import 'models.dart';

/// Filtro de uma lista de artigos (uma aba, um veículo, uma pasta, a busca).
class ArticleQuery {
  const ArticleQuery({
    this.view = 'all',
    this.feedId,
    this.folderId,
    this.q,
  });

  final String view; // all | unread | saved
  final int? feedId;
  final int? folderId;
  final String? q;

  ArticleQuery copyWith({String? view}) => ArticleQuery(
    view: view ?? this.view,
    feedId: feedId,
    folderId: folderId,
    q: q,
  );

  @override
  bool operator ==(Object other) =>
      other is ArticleQuery &&
      other.view == view &&
      other.feedId == feedId &&
      other.folderId == folderId &&
      other.q == q;

  @override
  int get hashCode => Object.hash(view, feedId, folderId, q);
}

class Api {
  Api(this._dio);

  final Dio _dio;

  Future<Json> _get(String path, [Map<String, dynamic>? query]) async {
    final r = await _dio.get<Json>(path, queryParameters: query);
    return r.data ?? const {};
  }

  Future<List<dynamic>> _list(String path) async {
    final r = await _dio.get<List<dynamic>>(path);
    return r.data ?? const [];
  }

  // ── Conta e preferências ────────────────────────────────────────────

  Future<User> me() async => User.fromJson(await _get('/api/auth/me'));

  Future<AuthConfig> authConfig() async =>
      AuthConfig.fromJson(await _get('/api/auth/config'));

  Future<Prefs> prefs() async => Prefs.fromJson(await _get('/api/prefs'));

  Future<Prefs> savePrefs(Prefs prefs) async {
    final r = await _dio.put<Json>('/api/prefs', data: prefs.toJson());
    return Prefs.fromJson(r.data ?? const {});
  }

  // ── Artigos ─────────────────────────────────────────────────────────

  Future<ResultPage<ArticleItem>> articles(
    ArticleQuery query, {
    String? cursor,
    int limit = 40,
  }) async {
    final data = await _get('/api/articles', {
      'view': query.view,
      'feed_id': ?query.feedId,
      'folder_id': ?query.folderId,
      if (query.q != null && query.q!.trim().isNotEmpty) 'q': query.q!.trim(),
      'cursor': ?cursor,
      'limit': limit,
    });
    return ResultPage(
      [
        for (final a in (data['items'] as List? ?? const []))
          ArticleItem.fromJson(a as Json),
      ],
      data['next_cursor'] as String?,
    );
  }

  Future<Article> article(int id) async =>
      Article.fromJson(await _get('/api/articles/$id'));

  Future<void> setState(int id, {bool? read, bool? saved}) => _dio.post<void>(
    '/api/articles/$id/state',
    data: {'read': ?read, 'saved': ?saved},
  );

  Future<int> markRead({int? feedId, int? folderId, DateTime? before}) async {
    final r = await _dio.post<Json>(
      '/api/articles/read',
      data: {
        'feed_id': ?feedId,
        'folder_id': ?folderId,
        if (before != null) 'before': before.toUtc().toIso8601String(),
      },
    );
    return r.data?['marked'] as int? ?? 0;
  }

  /// Tradução pronta (200), em andamento (202) ou nunca pedida (null).
  Future<TranslationState?> translation(int id, String lang) async {
    final r = await _dio.get<Json>(
      '/api/articles/$id/translation/$lang',
      options: Options(validateStatus: (s) => s != null && s < 500),
    );
    if (r.statusCode == 200) {
      return TranslationState(
        translation: Translation.fromJson(r.data!),
        state: 'done',
      );
    }
    if (r.statusCode == 202) return TranslationState.fromJson(r.data!);
    if (r.statusCode == 404) return null;
    throw DioException.badResponse(
      statusCode: r.statusCode ?? 0,
      requestOptions: r.requestOptions,
      response: r,
    );
  }

  Future<TranslationState> requestTranslation(int id, String lang) async {
    final r = await _dio.post<Json>('/api/articles/$id/translation/$lang');
    return TranslationState.fromJson(r.data ?? const {});
  }

  // ── Veículos e pastas ───────────────────────────────────────────────

  Future<List<Subscription>> subscriptions() async => [
    for (final s in await _list('/api/subscriptions'))
      Subscription.fromJson(s as Json),
  ];

  Future<Subscription> subscribe(String url, {int? folderId, String? title}) async {
    final r = await _dio.post<Json>(
      '/api/subscriptions',
      data: {'url': url, 'folder_id': ?folderId, 'title': ?title},
      options: Options(receiveTimeout: const Duration(seconds: 90)),
    );
    return Subscription.fromJson(r.data!);
  }

  Future<void> updateSubscription(
    int feedId, {
    String? title,
    int? folderId,
    bool clearFolder = false,
  }) => _dio.patch<void>(
    '/api/subscriptions/$feedId',
    data: {
      'title': ?title,
      'folder_id': ?folderId,
      'clear_folder': clearFolder,
    },
  );

  Future<void> unsubscribe(int feedId) =>
      _dio.delete<void>('/api/subscriptions/$feedId');

  Future<void> refreshFeed(int feedId) =>
      _dio.post<void>('/api/subscriptions/$feedId/refresh');

  Future<List<Folder>> folders() async => [
    for (final f in await _list('/api/folders')) Folder.fromJson(f as Json),
  ];

  Future<Folder> createFolder(String name) async {
    final r = await _dio.post<Json>('/api/folders', data: {'name': name});
    return Folder.fromJson(r.data!);
  }

  Future<void> renameFolder(int id, String name) =>
      _dio.patch<void>('/api/folders/$id', data: {'name': name});

  Future<void> deleteFolder(int id) => _dio.delete<void>('/api/folders/$id');

  Future<Uint8List> exportOpml() async {
    final r = await _dio.get<List<int>>(
      '/api/opml',
      options: Options(responseType: ResponseType.bytes),
    );
    return Uint8List.fromList(r.data ?? const []);
  }

  Future<ImportResult> importOpml(Uint8List bytes) async {
    final r = await _dio.post<Json>(
      '/api/opml',
      data: Stream.fromIterable([bytes]),
      options: Options(
        contentType: 'text/x-opml',
        headers: {Headers.contentLengthHeader: bytes.length},
        receiveTimeout: const Duration(minutes: 2),
      ),
    );
    return ImportResult.fromJson(r.data ?? const {});
  }

  // ── Histórias ───────────────────────────────────────────────────────

  Future<ResultPage<StoryItem>> stories({String? cursor, int days = 3}) async {
    final data = await _get('/api/stories', {
      'days': days,
      'cursor': ?cursor,
    });
    return ResultPage(
      [
        for (final s in (data['items'] as List? ?? const []))
          StoryItem.fromJson(s as Json),
      ],
      data['next_cursor'] as String?,
    );
  }

  Future<Story> story(int id) async =>
      Story.fromJson(await _get('/api/stories/$id'));

  Future<void> mergeStories(int target, int other) =>
      _dio.post<void>('/api/stories/$target/merge', data: {'other_id': other});

  Future<void> splitStory(int id, List<int> articleIds) => _dio.post<void>(
    '/api/stories/$id/split',
    data: {'article_ids': articleIds},
  );

  // ── Admin ───────────────────────────────────────────────────────────

  Future<List<AdminUser>> users() async => [
    for (final u in await _list('/api/admin/users'))
      AdminUser.fromJson(u as Json),
  ];

  Future<void> setUserDisabled(String id, bool disabled) => _dio.patch<void>(
    '/api/admin/users/$id',
    data: {'disabled': disabled},
  );

  Future<void> logoutUser(String id) =>
      _dio.post<void>('/api/admin/users/$id/logout');
}

final apiProvider = Provider<Api>((ref) => Api(ref.watch(dioProvider)));
