import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/session.dart';
import 'models.dart';

/// Chamadas que exigem conexão: conta, espaços, convites, preferências e a
/// página Usuários. O conteúdo dos módulos vai pelo sync, não por aqui.
class Api {
  Api(this._dio);

  final Dio _dio;

  Future<User> me() async =>
      User.fromJson((await _dio.get<Json>('/api/auth/me')).data!);

  // ── Espaços ──
  Future<Space> createSpace(String name, {String? color, String? icon}) async =>
      Space.fromJson((await _dio.post<Json>(
        '/api/spaces',
        data: {'name': name, 'color': ?color, 'icon': ?icon},
      )).data!);

  Future<Space> updateSpace(String id, {String? name, String? color, String? icon}) async =>
      Space.fromJson((await _dio.patch<Json>(
        '/api/spaces/$id',
        data: {'name': ?name, 'color': ?color, 'icon': ?icon},
      )).data!);

  Future<void> deleteSpace(String id) => _dio.delete<void>('/api/spaces/$id');

  Future<Space> setRole(String spaceId, String userId, String role) async =>
      Space.fromJson((await _dio.patch<Json>(
        '/api/spaces/$spaceId/members/$userId',
        data: {'role': role},
      )).data!);

  /// Tira alguém do grupo; com o próprio id, sai do grupo.
  Future<void> removeMember(String spaceId, String userId) =>
      _dio.delete<void>('/api/spaces/$spaceId/members/$userId');

  // ── Convites ──
  Future<CreatedInvite> createInvite(String spaceId, {int days = 7, int uses = 10}) async =>
      CreatedInvite.fromJson((await _dio.post<Json>(
        '/api/spaces/$spaceId/invites',
        data: {'days': days, 'uses': uses},
      )).data!);

  Future<InvitePreview> previewInvite(String token) async => InvitePreview.fromJson(
    (await _dio.get<Json>('/api/invites/${Uri.encodeComponent(token)}')).data!,
  );

  Future<Space> acceptInvite(String token) async => Space.fromJson(
    (await _dio.post<Json>('/api/invites/${Uri.encodeComponent(token)}/accept')).data!,
  );

  // ── Preferências ──
  Future<Prefs> prefs() async => Prefs.fromJson((await _dio.get<Json>('/api/prefs')).data!);

  Future<Prefs> savePrefs(Json changes) async =>
      Prefs.fromJson((await _dio.put<Json>('/api/prefs', data: changes)).data!);

  // ── Admin ──
  Future<List<AdminUser>> users() async => [
    for (final u in (await _dio.get<List<dynamic>>('/api/admin/users')).data!)
      AdminUser.fromJson(u as Json),
  ];

  Future<void> setUserDisabled(String id, bool disabled) =>
      _dio.patch<void>('/api/admin/users/$id', data: {'disabled': disabled});

  Future<void> logoutUser(String id) => _dio.post<void>('/api/admin/users/$id/logout');

  Future<Json> appVersion() async => (await _dio.get<Json>('/api/app/version')).data!;
}

final apiProvider = Provider<Api>((ref) => Api(ref.watch(dioProvider)));
