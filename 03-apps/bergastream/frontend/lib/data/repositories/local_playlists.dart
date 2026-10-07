import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/app_platform.dart';
import '../../core/storage/key_value_store.dart';

/// Playlist criada no aparelho sem login ("Só neste aparelho", Seção 6.4).
class LocalPlaylist {
  const LocalPlaylist({
    required this.id,
    required this.name,
    this.trackIds = const [],
  });

  factory LocalPlaylist.fromJson(Map<String, dynamic> json) => LocalPlaylist(
    id: json['id'] as String,
    name: json['name'] as String,
    trackIds: [for (final t in json['track_ids'] as List<dynamic>) t as String],
  );

  final String id;
  final String name;

  /// Ids das faixas baixadas (entram com o banco local, Passo 9).
  final List<String> trackIds;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'track_ids': trackIds,
  };
}

/// Playlists locais. Por enquanto no armazenamento local; o Passo 9 move
/// para o banco local junto com as músicas baixadas.
class LocalPlaylists extends Notifier<List<LocalPlaylist>> {
  String get _key =>
      '${ref.read(appPlatformProvider).simulated ? 'sim_android.' : ''}local_playlists';

  KeyValueStore get _store => ref.read(keyValueStoreProvider);

  late Future<void> _loading;

  /// Termina quando as playlists guardadas foram lidas.
  Future<void> get loaded => _loading;

  @override
  List<LocalPlaylist> build() {
    _loading = _load();
    return const [];
  }

  Future<void> _load() async {
    final raw = await _store.read(_key);
    if (raw == null) return;
    state = [
      for (final p in jsonDecode(raw) as List<dynamic>)
        LocalPlaylist.fromJson(p as Map<String, dynamic>),
    ];
  }

  Future<void> _save() =>
      _store.write(_key, jsonEncode([for (final p in state) p.toJson()]));

  Future<LocalPlaylist> create(String name) async {
    final p = LocalPlaylist(
      id: 'local-${DateTime.now().microsecondsSinceEpoch}',
      name: name,
    );
    state = [...state, p];
    await _save();
    return p;
  }

  Future<void> rename(String id, String name) async {
    state = [
      for (final p in state)
        p.id == id
            ? LocalPlaylist(id: id, name: name, trackIds: p.trackIds)
            : p,
    ];
    await _save();
  }

  Future<void> delete(String id) async {
    state = [
      for (final p in state)
        if (p.id != id) p,
    ];
    await _save();
  }
}

final localPlaylistsProvider =
    NotifierProvider<LocalPlaylists, List<LocalPlaylist>>(LocalPlaylists.new);
