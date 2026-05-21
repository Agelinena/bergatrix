import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../core/api_client.dart';
import '../core/offline_cache.dart';
import '../core/storage.dart';
import '../models/user.dart';

part 'auth_provider.g.dart';

/// Key used to cache the most recent AppUser payload locally so the user
/// can launch the app while offline.  Stored as JSON in SharedPreferences.
const _cachedUserKey = 'cached_user_json';

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

    // Optimistic: if we have a cached user, expose it immediately so the
    // app boots into the authenticated UI even while the network call to
    // /api/auth/me is pending.  We refresh in the background and only
    // log out if the server explicitly returns 401.
    final cached = await _loadCachedUser();
    if (cached != null) {
      state = AsyncValue.data(cached);
    }

    try {
      final data = await client.getMe();
      final user = AppUser.fromJson(data);
      await _saveCachedUser(data);
      state = AsyncValue.data(user);
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      final isAuthError = status == 401 || status == 403;
      if (isAuthError) {
        // Server explicitly invalidated us — clear token + cache.
        await client.clearToken();
        await AppStorage.remove(_cachedUserKey);
        state = const AsyncValue.data(null);
      } else {
        // Network error, timeout, server down, etc.  Stay authenticated
        // using the cached user so the user can browse offline-saved
        // content. If we had no cached user, fall back to logged-out.
        debugPrint('[Auth] initialize: network error (${e.type}) — staying offline');
        if (cached == null) {
          state = const AsyncValue.data(null);
        }
        // else: state was already set to cached above; keep it.
      }
    } catch (e) {
      debugPrint('[Auth] initialize: unexpected error: $e');
      if (cached == null) {
        await client.clearToken();
        state = const AsyncValue.data(null);
      }
    }
  }

  Future<void> login(String email, String password) async {
    state = const AsyncValue.loading();
    try {
      final client = ref.read(apiClientProvider);
      final data = await client.login(email, password);
      await client.saveToken(data['access_token'] as String);
      final me = await client.getMe();
      await _saveCachedUser(me);
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
      await _saveCachedUser(me);
      state = AsyncValue.data(AppUser.fromJson(me));
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> logout() async {
    final client = ref.read(apiClientProvider);
    await client.logout();
    await AppStorage.remove(_cachedUserKey);
    // Wipe per-user offline payload cache so the next user doesn't see
    // somebody else's playlists.
    await OfflineCache.clearAll();
    state = const AsyncValue.data(null);
  }

  Future<void> updateUsername(String username) async {
    final client = ref.read(apiClientProvider);
    final data = await client.updateMe(username: username);
    await _saveCachedUser(data);
    state = AsyncValue.data(AppUser.fromJson(data));
  }

  // ── Cached user helpers ────────────────────────────────────────────────

  Future<AppUser?> _loadCachedUser() async {
    try {
      final raw = await AppStorage.getString(_cachedUserKey);
      if (raw == null) return null;
      return AppUser.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (e) {
      debugPrint('[Auth] _loadCachedUser failed: $e');
      return null;
    }
  }

  Future<void> _saveCachedUser(Map<String, dynamic> data) async {
    try {
      await AppStorage.setString(_cachedUserKey, jsonEncode(data));
    } catch (e) {
      debugPrint('[Auth] _saveCachedUser failed: $e');
    }
  }

  AppUser? get user => state.valueOrNull;
  bool get isAuthenticated => user != null;
}
