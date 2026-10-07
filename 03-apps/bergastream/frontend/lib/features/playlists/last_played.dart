import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/app_platform.dart';
import '../../core/storage/key_value_store.dart';
import '../../data/models/playlist_models.dart';

/// Quando cada playlist começou a tocar neste aparelho. Junto com o
/// `last_played_at` do servidor (de qualquer aparelho), ordena a Biblioteca:
/// a última tocada fica no topo, na hora, mesmo sem servidor.
class PlaylistLastPlayed extends Notifier<Map<String, DateTime>> {
  String get _key =>
      '${ref.read(appPlatformProvider).simulated ? 'sim_android.' : ''}playlists.last_played';

  KeyValueStore get _store => ref.read(keyValueStoreProvider);

  @override
  Map<String, DateTime> build() {
    _load();
    return const {};
  }

  Future<void> _load() async {
    final raw = await _store.read(_key);
    if (raw == null) return;
    state = {
      ...{
        for (final e in (jsonDecode(raw) as Map<String, dynamic>).entries)
          e.key: ?DateTime.tryParse(e.value as String),
      },
      ...state,
    };
  }

  Future<void> touch(String playlistId, [DateTime? at]) async {
    state = {...state, playlistId: at ?? DateTime.now()};
    await _store.write(
      _key,
      jsonEncode({
        for (final e in state.entries) e.key: e.value.toUtc().toIso8601String(),
      }),
    );
  }
}

final playlistLastPlayedProvider =
    NotifierProvider<PlaylistLastPlayed, Map<String, DateTime>>(
      PlaylistLastPlayed.new,
    );

/// Última tocada primeiro (servidor ou este aparelho, o mais recente); as
/// nunca tocadas depois, na ordem em que vieram.
List<ServerPlaylist> sortByLastPlayed(
  List<ServerPlaylist> playlists,
  Map<String, DateTime> local,
) {
  DateTime? when(ServerPlaylist p) {
    final server = DateTime.tryParse(p.lastPlayedAt ?? '');
    final here = local[p.id];
    if (server == null) return here;
    if (here == null) return server;
    return here.isAfter(server) ? here : server;
  }

  final indexed = [for (final (i, p) in playlists.indexed) (i, p, when(p))];
  indexed.sort((a, b) {
    final (ia, _, wa) = a;
    final (ib, _, wb) = b;
    if (wa != null && wb != null) {
      final c = wb.compareTo(wa);
      if (c != 0) return c;
    } else if (wa != null) {
      return -1;
    } else if (wb != null) {
      return 1;
    }
    return ia.compareTo(ib);
  });
  return [for (final (_, p, _) in indexed) p];
}
