import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_error.dart';
import '../../data/local/database.dart';
import '../../data/models/playlist_models.dart';
import '../../data/repositories/history_repository.dart';
import '../../data/repositories/playlist_repository.dart';
import '../auth/session.dart';
import '../downloads/download_manager.dart';
import '../home/home_providers.dart';
import '../library/library_providers.dart';
import '../settings/preferences.dart';

/// Diferença entre a playlist no servidor e a cópia baixada.
class PlaylistChanges {
  const PlaylistChanges({required this.added, required this.removed});

  static const none = PlaylistChanges(added: 0, removed: 0);

  final int added;
  final int removed;

  bool get isEmpty => added == 0 && removed == 0;
}

/// Compara a playlist do servidor com a cópia baixada (selo "N novas
/// músicas", Seção 8.4).
Future<PlaylistChanges> compareWithDownload(
  AppDatabase db,
  PlaylistDetail server,
) async {
  if (await db.playlist(server.id) == null) return PlaylistChanges.none;
  final local = {
    for (final (track, _) in await db.watchPlaylistTracks(server.id).first)
      track.id,
  };
  final remote = {for (final t in server.tracks) t.trackId};
  return PlaylistChanges(
    added: remote.difference(local).length,
    removed: local.difference(remote).length,
  );
}

/// Sincronização ao reconectar (Passo 11): envia as reproduções pendentes e,
/// se ligado, atualiza as playlists baixadas que mudaram.
class SyncService extends Notifier<void> {
  bool _running = false;

  @override
  void build() {
    ref.listen(sessionProvider.select((s) => s.canUseServer), (_, online) {
      if (online) run();
    });
  }

  Future<void> run() async {
    if (_running || !ref.read(sessionProvider).canUseServer) return;
    _running = true;
    try {
      await sendPendingPlays();
      if (ref.read(preferencesProvider).autoDownloadNew) {
        await updateDownloadedPlaylists();
      }
    } finally {
      _running = false;
    }
  }

  /// Envia as reproduções feitas offline, na ordem, em lotes. Só apaga do
  /// aparelho o que o servidor aceitou; reenviar não duplica (client_id).
  Future<int> sendPendingPlays() async {
    final db = ref.read(localDatabaseProvider);
    if (db == null) return 0;
    final pending = await db.pendingPlaysInOrder();
    var sent = 0;
    for (var start = 0; start < pending.length; start += 200) {
      final batch = pending.skip(start).take(200).toList();
      try {
        await ref.read(historyRepositoryProvider).record([
          for (final p in batch)
            PlayRecord.fromJson(
              jsonDecode(p.trackJson) as Map<String, dynamic>,
            ),
        ]);
      } on ApiException catch (e) {
        debugPrint('Reproduções pendentes ficam para depois: ${e.message}');
        break;
      }
      await db.deletePendingPlays([for (final p in batch) p.id]);
      sent += batch.length;
    }
    if (sent > 0) ref.invalidate(homeStatsProvider);
    return sent;
  }

  /// "Atualizar download" das playlists baixadas que mudaram no servidor:
  /// baixa as novas e libera as retiradas (contagem de referências).
  Future<int> updateDownloadedPlaylists() async {
    final db = ref.read(localDatabaseProvider);
    if (db == null) return 0;
    final summaries = {
      for (final p in await ref.read(playlistRepositoryProvider).myPlaylists())
        p.id: p,
    };
    var updated = 0;
    for (final local in await db.watchPlaylists().first) {
      final remote = summaries[local.id];
      if (remote == null || remote.updatedAt == local.serverUpdatedAt) continue;
      final detail = await ref
          .read(playlistRepositoryProvider)
          .detail(local.id);
      await ref.read(downloadManagerProvider.notifier).downloadPlaylist(detail);
      updated++;
    }
    if (updated > 0) ref.invalidate(myPlaylistsProvider);
    return updated;
  }
}

final syncServiceProvider = NotifierProvider<SyncService, void>(
  SyncService.new,
);

/// Selo da playlist: mudanças do servidor em relação à cópia baixada.
final playlistChangesProvider = FutureProvider.autoDispose
    .family<PlaylistChanges, String>((ref, id) async {
      final db = ref.watch(localDatabaseProvider);
      if (db == null ||
          !ref.watch(sessionProvider.select((s) => s.canUseServer))) {
        return PlaylistChanges.none;
      }
      ref.watch(downloadedPlaylistsProvider);
      ref.watch(playlistDownloadProvider(id));
      final detail = await ref.watch(playlistDetailProvider(id).future);
      return compareWithDownload(db, detail);
    }, retry: (_, _) => null);
