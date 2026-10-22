import 'dart:async';
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
import '../playlists/playlist_store.dart';
import '../settings/preferences.dart';
import 'playlist_signal.dart';
import 'server_monitor.dart';

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

/// Resultado do "Sincronizar agora" (mostrado num aviso).
class SyncReport {
  const SyncReport({
    this.offline = false,
    this.failed = false,
    this.sent = 0,
    this.pending = 0,
    this.plays = 0,
    this.updated = 0,
  });

  /// Servidor fora do ar: nada foi enviado nem buscado.
  final bool offline;

  /// Alguma parte não respondeu (o resto foi feito).
  final bool failed;

  /// Alterações de playlist enviadas e as que ainda ficaram no aparelho.
  final int sent;
  final int pending;

  /// Reproduções offline enviadas.
  final int plays;

  /// Playlists baixadas que ganharam (ou perderam) músicas.
  final int updated;

  String get message {
    if (offline) {
      return pending > 0
          ? 'Sem conexão com o servidor. $pending '
                '${pending == 1 ? 'alteração fica guardada' : 'alterações ficam guardadas'}'
                ' e vai quando ele voltar.'
          : 'Sem conexão com o servidor. Tente de novo quando ele voltar.';
    }
    if (pending > 0) {
      return '$pending ${pending == 1 ? 'alteração ainda não foi' : 'alterações ainda não foram'}'
          ' para a nuvem. O app tenta de novo sozinho.';
    }
    if (failed) return 'Não foi possível sincronizar tudo. Tente de novo.';
    final parts = [
      if (sent > 0)
        '$sent ${sent == 1 ? 'alteração enviada' : 'alterações enviadas'}',
      if (updated > 0)
        '$updated ${updated == 1 ? 'playlist baixada atualizada' : 'playlists baixadas atualizadas'}',
    ];
    return parts.isEmpty
        ? 'Tudo sincronizado com a nuvem.'
        : 'Sincronizado: ${parts.join(', ')}.';
  }
}

/// Sincronização com o servidor:
/// - ao reconectar e ao voltar ao app (Passo 11): envia as alterações e as
///   reproduções pendentes e, se ligado, atualiza as playlists baixadas;
/// - quando o servidor avisa que playlists mudaram (outro aparelho, outra
///   pessoa da playlist): busca de novo a Biblioteca e a playlist aberta;
/// - "Sincronizar agora" ([syncNow]). Estado: verdadeiro enquanto ele roda.
class SyncService extends Notifier<bool> {
  bool _running = false;
  Future<SyncReport>? _manual;
  Timer? _changed;

  @override
  bool build() {
    ref.listen(sessionProvider.select((s) => s.canUseServer), (_, online) {
      if (online) run();
    });
    // Vários avisos seguidos (importação em andamento) viram uma busca só.
    final signal = ref.read(playlistsChangedSignalProvider).stream.listen((_) {
      _changed?.cancel();
      _changed = Timer(const Duration(milliseconds: 600), () {
        _changed = null;
        if (ref.mounted) unawaited(refreshFromServer());
      });
    });
    ref.onDispose(() {
      signal.cancel();
      _changed?.cancel();
    });
    return false;
  }

  /// Busca de novo as playlists (Biblioteca e as abertas) e, se ligado,
  /// atualiza as baixadas que mudaram.
  Future<void> refreshFromServer() async {
    final session = ref.read(sessionProvider);
    if (!session.canUseServer) return;
    ref.invalidate(serverPlaylistsProvider);
    ref.invalidate(serverPlaylistDetailProvider);
    if (ref.read(preferencesProvider).autoDownloadNew) {
      try {
        await updateDownloadedPlaylists();
      } on ApiException catch (e) {
        debugPrint('Playlists baixadas ficam para depois: ${e.message}');
      }
    }
  }

  /// "Sincronizar agora": envia o que está no aparelho, traz as playlists da
  /// nuvem e atualiza as baixadas (mesmo sem "baixar novas automaticamente":
  /// foi a pessoa que pediu).
  Future<SyncReport> syncNow() =>
      _manual ??= _syncNow().whenComplete(() => _manual = null);

  Future<SyncReport> _syncNow() async {
    state = true;
    try {
      if (!ref.read(sessionProvider).isLoggedIn) {
        return const SyncReport(offline: true);
      }
      if (!ref.read(sessionProvider).canUseServer) {
        await ref.read(serverMonitorProvider.notifier).check();
        if (!ref.mounted || !ref.read(sessionProvider).canUseServer) {
          return SyncReport(offline: true, pending: await _pendingOps());
        }
      }
      final outcome = await ref.read(playlistSyncProvider.notifier).flush();
      final plays = await sendPendingPlays();
      ref.invalidate(serverPlaylistsProvider);
      ref.invalidate(serverPlaylistDetailProvider);
      var failed = false;
      try {
        await ref.read(serverPlaylistsProvider.future);
      } on Object {
        failed = true;
      }
      var updated = 0;
      try {
        updated = await updateDownloadedPlaylists();
      } on ApiException catch (e) {
        debugPrint('Playlists baixadas ficam para depois: ${e.message}');
        failed = true;
      }
      return SyncReport(
        failed: failed,
        sent: outcome.sent,
        pending: await _pendingOps(),
        plays: plays,
        updated: updated,
      );
    } finally {
      if (ref.mounted) state = false;
    }
  }

  Future<int> _pendingOps() async =>
      (await ref.read(localDatabaseProvider)?.playlistOpsInOrder())?.length ??
      0;

  Future<void> run() async {
    if (_running || !ref.read(sessionProvider).canUseServer) return;
    _running = true;
    try {
      // Alterações de playlist feitas offline primeiro: o resto (downloads)
      // já vê o resultado.
      await ref.read(playlistSyncProvider.notifier).flush();
      await sendPendingPlays();
      // O que mudou em outros aparelhos enquanto este estava fora.
      ref.invalidate(serverPlaylistsProvider);
      ref.invalidate(serverPlaylistDetailProvider);
      if (ref.read(preferencesProvider).autoDownloadNew) {
        try {
          await updateDownloadedPlaylists();
        } on ApiException catch (e) {
          debugPrint('Playlists baixadas ficam para depois: ${e.message}');
        }
      }
      // Cópias offline na qualidade escolhida (e trocadas quando o servidor
      // melhora a música).
      try {
        await ref.read(downloadManagerProvider.notifier).refreshQuality();
      } on ApiException catch (e) {
        debugPrint('Conferência da qualidade fica para depois: ${e.message}');
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
      final PlaylistDetail detail;
      try {
        detail = await ref.read(playlistRepositoryProvider).detail(local.id);
      } on ApiException catch (e) {
        // Uma playlist que falhou não segura as outras.
        if (e.isTransient) rethrow;
        debugPrint('Playlist baixada ${local.id} não atualizada: ${e.message}');
        continue;
      }
      await ref.read(downloadManagerProvider.notifier).downloadPlaylist(detail);
      updated++;
    }
    if (updated > 0) ref.invalidate(serverPlaylistsProvider);
    return updated;
  }
}

final syncServiceProvider = NotifierProvider<SyncService, bool>(
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
