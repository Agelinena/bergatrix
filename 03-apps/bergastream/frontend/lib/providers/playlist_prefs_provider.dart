/// Per-playlist user preferences that survive across app launches:
/// the shuffle toggle and the chosen sort mode.
///
/// Persisted as plain key-value pairs under SharedPreferences so the
/// state survives logout/login (intended — these are UX choices).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../core/storage.dart';

part 'playlist_prefs_provider.g.dart';

/// Sort modes available in the playlist dropdown.  Order in the enum
/// is the order shown to the user.
enum PlaylistSortMode {
  custom('Ordem personalizada'),
  title('Título'),
  artist('Artista'),
  album('Álbum'),
  addedBy('Adicionada por'),
  addedRecently('Adicionado recentemente'),
  duration('Duração');

  final String label;
  const PlaylistSortMode(this.label);

  static PlaylistSortMode fromString(String? value) {
    return PlaylistSortMode.values.firstWhere(
      (m) => m.name == value,
      orElse: () => PlaylistSortMode.custom,
    );
  }
}

String _shuffleKey(String playlistId) => 'playlist_shuffle_$playlistId';
String _sortKey(String playlistId) => 'playlist_sort_$playlistId';
String _sortDescKey(String playlistId) => 'playlist_sort_desc_$playlistId';

/// `(shuffle, sort, descending)` triple persisted per playlist id.
class PlaylistPrefs {
  final bool shuffle;
  final PlaylistSortMode sort;
  final bool descending;

  const PlaylistPrefs({
    this.shuffle = false,
    this.sort = PlaylistSortMode.custom,
    this.descending = false,
  });

  PlaylistPrefs copyWith({bool? shuffle, PlaylistSortMode? sort, bool? descending}) =>
      PlaylistPrefs(
        shuffle: shuffle ?? this.shuffle,
        sort: sort ?? this.sort,
        descending: descending ?? this.descending,
      );
}

@riverpod
class PlaylistPreferences extends _$PlaylistPreferences {
  @override
  PlaylistPrefs build(String playlistId) {
    // Initial value while we async-load; UI will rebuild on the listen.
    _load(playlistId);
    return const PlaylistPrefs();
  }

  Future<void> _load(String playlistId) async {
    final shuffleStr = await AppStorage.getString(_shuffleKey(playlistId));
    final sortStr = await AppStorage.getString(_sortKey(playlistId));
    final descStr = await AppStorage.getString(_sortDescKey(playlistId));
    state = PlaylistPrefs(
      shuffle: shuffleStr == 'true',
      sort: PlaylistSortMode.fromString(sortStr),
      descending: descStr == 'true',
    );
  }

  Future<void> setShuffle(bool value) async {
    state = state.copyWith(shuffle: value);
    await AppStorage.setString(_shuffleKey(playlistId), value.toString());
  }

  Future<void> setSort(PlaylistSortMode mode) async {
    // Toggle direction when the same mode is selected again (matches
    // Spotify's behaviour).
    final newDesc = state.sort == mode ? !state.descending : false;
    state = state.copyWith(sort: mode, descending: newDesc);
    await AppStorage.setString(_sortKey(playlistId), mode.name);
    await AppStorage.setString(_sortDescKey(playlistId), newDesc.toString());
  }
}
