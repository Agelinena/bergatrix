import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../models/user.dart';
import '../core/api_client.dart';

part 'auth_provider.g.dart';

enum AuthStatus { unknown, authenticated, unauthenticated }

@Riverpod(keepAlive: true)
class Auth extends _$Auth {
  @override
  AsyncValue<AppUser?> build() => const AsyncValue.loading();

  Future<void> initialize() async {
    final client = ref.read(apiClientProvider);
    final token = await client.getToken();
    if (token == null) {
      state = const AsyncValue.data(null);
      return;
    }
    try {
      final data = await client.getMe();
      state = AsyncValue.data(AppUser.fromJson(data));
    } catch (_) {
      await client.clearToken();
      state = const AsyncValue.data(null);
    }
  }

  Future<void> login(String email, String password) async {
    state = const AsyncValue.loading();
    try {
      final client = ref.read(apiClientProvider);
      final data = await client.login(email, password);
      await client.saveToken(data['access_token'] as String);
      final me = await client.getMe();
      state = AsyncValue.data(AppUser.fromJson(me));
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> register(String username, String email, String password) async {
    state = const AsyncValue.loading();
    try {
      final client = ref.read(apiClientProvider);
      final data = await client.register(username, email, password);
      await client.saveToken(data['access_token'] as String);
      final me = await client.getMe();
      state = AsyncValue.data(AppUser.fromJson(me));
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> logout() async {
    final client = ref.read(apiClientProvider);
    await client.logout();
    state = const AsyncValue.data(null);
  }

  Future<void> updateUsername(String username) async {
    final client = ref.read(apiClientProvider);
    final data = await client.updateMe(username: username);
    state = AsyncValue.data(AppUser.fromJson(data));
  }

  AppUser? get user => state.valueOrNull;
  bool get isAuthenticated => user != null;
}
