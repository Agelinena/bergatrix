import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../models/playlist.dart';
import '../models/track.dart';
import '../core/api_client.dart';
import '../core/offline_cache.dart';

part 'library_provider.g.dart';

// Cache keys for the offline fallback.
const _kCachePlaylists = 'playlists';
const _kCacheLikedSongs = 'liked_songs';

@riverpod
class Library extends _$Library {
  @override
  AsyncValue<List<Playlist>> build() => const AsyncValue.loading();

  Future<void> load() async {
    // Show whatever is cached immediately so the UI isn't blank while we
    // hit the network.  This makes the library feel instant for both
    // online users (warm cache) and offline users.
    final cached = await OfflineCache.getList(_kCachePlaylists);
    if (cached.isNotEmpty && state is! AsyncData<List<Playlist>>) {
      try {
        state = AsyncValue.data(
          cached.map((p) => Playlist.fromJson(p as Map<String, dynamic>)).toList(),
        );
      } catch (e) {
        debugPrint('[Library] cached payload unparseable: $e');
      }
    } else if (state is! AsyncData<List<Playlist>>) {
      state = const AsyncValue.loading();
    }

    try {
      final client = ref.read(apiClientProvider);
      final data = await client.getPlaylists();
      final playlists = data
          .map((p) => Playlist.fromJson(p as Map<String, dynamic>))
          .toList();
      state = AsyncValue.data(playlists);
      // Persist for offline use next launch.
      await OfflineCache.set(_kCachePlaylists, data);
    } catch (e, st) {
      // Network failed.  If we already have cached data displayed, leave
      // it in place — failing the whole list because the device is
      // offline would be hostile.  Only surface error when we have
      // nothing to show.
      if (state is! AsyncData<List<Playlist>>) {
        state = AsyncValue.error(e, st);
      } else {
        debugPrint('[Library] load failed, keeping cached data: $e');
      }
    }
  }

  Future<void> createPlaylist(String name, {String? description, bool isPublic = false}) async {
    final client = ref.read(apiClientProvider);
    await client.createPlaylist(name, description: description, isPublic: isPublic);
    await load();
  }

  Future<void> updatePlaylist(String id, {String? name, String? description, String? coverUrl, bool? isPublic}) async {
    final client = ref.read(apiClientProvider);
    await client.updatePlaylist(id, name: name, description: description, coverUrl: coverUrl, isPublic: isPublic);
    await load();
  }

  Future<void> deletePlaylist(String id) async {
    final client = ref.read(apiClientProvider);
    await client.deletePlaylist(id);
    await load();
  }

  Future<bool> tryDeletePlaylist(String id) async {
    try {
      await deletePlaylist(id);
      return true;
    } catch (_) {
      return false;
    }
  }
}

@riverpod
class LikedSongs extends _$LikedSongs {
  @override
  AsyncValue<List<Track>> build() => const AsyncValue.loading();

  Future<void> load() async {
    final cached = await OfflineCache.getList(_kCacheLikedSongs);
    if (cached.isNotEmpty && state is! AsyncData<List<Track>>) {
      try {
        state = AsyncValue.data(
          cached.map((t) => Track.fromJson(t as Map<String, dynamic>)).toList(),
        );
      } catch (e) {
        debugPrint('[LikedSongs] cached payload unparseable: $e');
      }
    } else if (state is! AsyncData<List<Track>>) {
      state = const AsyncValue.loading();
    }

    try {
      final client = ref.read(apiClientProvider);
      final data = await client.getLikedTracks();
      final tracks = data.map((t) => Track.fromJson(t as Map<String, dynamic>)).toList();
      state = AsyncValue.data(tracks);
      await OfflineCache.set(_kCacheLikedSongs, data);
    } catch (e, st) {
      if (state is! AsyncData<List<Track>>) {
        state = AsyncValue.error(e, st);
      } else {
        debugPrint('[LikedSongs] load failed, keeping cached data: $e');
      }
    }
  }
}
