import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../models/playlist.dart';
import '../models/track.dart';
import '../core/api_client.dart';

part 'library_provider.g.dart';

@riverpod
class Library extends _$Library {
  @override
  AsyncValue<List<Playlist>> build() => const AsyncValue.loading();

  Future<void> load() async {
    state = const AsyncValue.loading();
    try {
      final client = ref.read(apiClientProvider);
      final data = await client.getPlaylists();
      final playlists = data.map((p) => Playlist.fromJson(p as Map<String, dynamic>)).toList();
      state = AsyncValue.data(playlists);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
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
    state = const AsyncValue.loading();
    try {
      final client = ref.read(apiClientProvider);
      final data = await client.getLikedTracks();
      final tracks = data.map((t) => Track.fromJson(t as Map<String, dynamic>)).toList();
      state = AsyncValue.data(tracks);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }
}
