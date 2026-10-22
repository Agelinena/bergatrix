import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/app_platform.dart';
import '../../core/storage/key_value_store.dart';
import '../../features/downloads/download_manager.dart';

/// Playlist criada no aparelho sem login ("Só neste aparelho", Seção 6.4).
class LocalPlaylist {
  const LocalPlaylist({
    required this.id,
    required this.name,
    this.trackIds = const [],
    this.coverPath,
  });

  factory LocalPlaylist.fromJson(Map<String, dynamic> json) => LocalPlaylist(
    id: json['id'] as String,
    name: json['name'] as String,
    trackIds: [for (final t in json['track_ids'] as List<dynamic>) t as String],
    coverPath: json['cover_path'] as String?,
  );

  final String id;
  final String name;

  /// Foto escolhida no aparelho (arquivo na pasta das capas).
  final String? coverPath;

  LocalPlaylist copyWith({
    String? name,
    String? coverPath,
    bool clearCover = false,
  }) => LocalPlaylist(
    id: id,
    name: name ?? this.name,
    trackIds: trackIds,
    coverPath: clearCover ? null : coverPath ?? this.coverPath,
  );

  /// Ids das faixas baixadas (entram com o banco local, Passo 9).
  final List<String> trackIds;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'track_ids': trackIds,
    'cover_path': ?coverPath,
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
    state = [for (final p in state) p.id == id ? p.copyWith(name: name) : p];
    await _save();
  }

  /// "Trocar foto": guarda a imagem na pasta das capas (nome novo a cada
  /// troca, para a tela não mostrar a antiga do cache de imagens).
  Future<void> setCover(String id, List<int> bytes) async {
    final current = state.where((p) => p.id == id).firstOrNull;
    if (current == null) return;
    final dir = (await ref.read(downloadPathsProvider)()).covers;
    final path = '$dir/$id-${DateTime.now().millisecondsSinceEpoch}.img';
    await File(path).writeAsBytes(bytes, flush: true);
    _deleteCover(current.coverPath);
    state = [
      for (final p in state) p.id == id ? p.copyWith(coverPath: path) : p,
    ];
    await _save();
  }

  /// Apaga a playlist e a foto dela.
  Future<void> delete(String id) async {
    final gone = state.where((p) => p.id == id).firstOrNull;
    state = [
      for (final p in state)
        if (p.id != id) p,
    ];
    await _save();
    _deleteCover(gone?.coverPath);
  }

  static void _deleteCover(String? path) {
    if (path == null) return;
    try {
      File(path).deleteSync();
    } on FileSystemException catch (e) {
      debugPrint('Foto da playlist local não apagada: ${e.message}');
    }
  }
}

final localPlaylistsProvider =
    NotifierProvider<LocalPlaylists, List<LocalPlaylist>>(LocalPlaylists.new);
