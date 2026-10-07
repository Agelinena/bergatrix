import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_error.dart';
import '../../data/local/database.dart';
import '../../data/models/playlist_models.dart';
import '../../data/models/playlist_op.dart';
import '../../data/models/search_result.dart';
import '../../data/repositories/playlist_repository.dart';
import '../auth/session.dart';
import '../downloads/offline_playlists.dart';
import 'playlist_merge.dart';

// Playlists do servidor com edição offline.
//
// - Toda alteração feita no app vira uma [PlaylistOp] (intenção) numa fila
//   no aparelho e aparece na tela na hora ([applyOpsToDetail]).
// - Com servidor, a fila é enviada em seguida; sem servidor, quando ele
//   voltar ([PlaylistSync.flush]).
// - O servidor aplica as intenções sobre o estado atual (o que mudou na web
//   nesse meio-tempo é preservado). Conflitos de verdade (nome mudou nos dois
//   lados, playlist apagada aqui e alterada lá, alterações numa playlist
//   apagada lá) viram [SyncNotice] para a pessoa decidir.
// - Na web não há fila: a alteração vai direto e a tela é recarregada.

Duration? _noRetry(int retryCount, Object error) => null;

/// A conta conhecida pelo aparelho (logada ou com a sessão expirada): a
/// cópia local e a fila valem para ela.
bool hasAccount(SessionState s) =>
    s.username != null &&
    (s.isLoggedIn || s.status == SessionStatus.sessaoExpirada);

Person _me(SessionState s) =>
    Person(id: '', username: s.username ?? '', name: s.username ?? '');

// ── Cópia local do que veio do servidor ─────────────────────────────

/// Última versão vista de cada playlist (para abrir e editar offline) e os
/// ids que o servidor deu às playlists/faixas criadas offline.
class PlaylistCache {
  PlaylistCache(this._db);

  final AppDatabase _db;

  static const _listKey = 'playlists.cache.list';
  static String _detailKey(String id) => 'playlists.cache.detail.$id';
  static const _aliasesKey = 'playlists.aliases';
  static const _userKey = 'playlists.user';

  Future<List<ServerPlaylist>?> list() async {
    final raw = await _db.stateValue(_listKey);
    if (raw == null) return null;
    return [
      for (final p in jsonDecode(raw) as List<dynamic>)
        ServerPlaylist.fromJson(p as Map<String, dynamic>),
    ];
  }

  Future<void> saveList(List<ServerPlaylist> list) => _db.setStateValue(
    _listKey,
    jsonEncode([for (final p in list) p.toJson()]),
  );

  Future<PlaylistDetail?> detail(String id) async {
    final raw = await _db.stateValue(_detailKey(id));
    return raw == null
        ? null
        : PlaylistDetail.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> saveDetail(PlaylistDetail p) =>
      _db.setStateValue(_detailKey(p.id), jsonEncode(p.toJson()));

  Future<Map<String, String>> aliases() async {
    final raw = await _db.stateValue(_aliasesKey);
    if (raw == null) return const {};
    return (jsonDecode(raw) as Map<String, dynamic>).cast<String, String>();
  }

  Future<void> addAliases(Map<String, String> refs) async {
    if (refs.isEmpty) return;
    await _db.setStateValue(
      _aliasesKey,
      jsonEncode({...await aliases(), ...refs}),
    );
  }

  /// Dono da cópia e da fila. Outra conta no mesmo aparelho começa do zero.
  Future<String?> user() => _db.stateValue(_userKey);

  Future<void> setUser(String username) =>
      _db.setStateValue(_userKey, username);

  /// Apaga cópia, fila e avisos (sair da conta ou trocar de conta).
  Future<void> clearAll() async {
    final list = await this.list() ?? const [];
    for (final p in list) {
      await _db.deleteStateValue(_detailKey(p.id));
    }
    for (final key in [_listKey, _aliasesKey, _userKey]) {
      await _db.deleteStateValue(key);
    }
    final ops = await _db.playlistOpsInOrder();
    await _db.deletePlaylistOps([for (final o in ops) o.seq]);
    await _db.clearNotices();
  }
}

/// Nulo na web (sem banco local).
final playlistCacheProvider = Provider<PlaylistCache?>((ref) {
  final db = ref.watch(localDatabaseProvider);
  return db == null ? null : PlaylistCache(db);
});

final playlistAliasesProvider = FutureProvider<Map<String, String>>(
  (ref) async => await ref.watch(playlistCacheProvider)?.aliases() ?? const {},
);

// ── Fila ────────────────────────────────────────────────────────────

class PendingOp {
  const PendingOp(this.seq, this.op);

  final int seq;
  final PlaylistOp op;
}

final pendingPlaylistOpsProvider = StreamProvider<List<PendingOp>>((ref) {
  final db = ref.watch(localDatabaseProvider);
  if (db == null) return Stream.value(const []);
  return db.watchPlaylistOps().map(
    (rows) => [
      for (final r in rows)
        PendingOp(
          r.seq,
          PlaylistOp.fromJson(jsonDecode(r.opJson) as Map<String, dynamic>),
        ),
    ],
  );
});

/// Ids de playlists com alterações ainda não enviadas.
final pendingPlaylistIdsProvider = Provider<Set<String>>((ref) {
  final ops = ref.watch(pendingPlaylistOpsProvider).value ?? const [];
  return {for (final p in ops) p.op.playlist};
});

// ── Avisos (conflitos) ──────────────────────────────────────────────

enum SyncNoticeKind {
  /// O nome mudou aqui e no servidor; ficou o do servidor.
  renameConflict,

  /// Apagada aqui, mas mudou no servidor depois; não foi apagada.
  deleteConflict,

  /// Alterações numa playlist que foi apagada em outro lugar.
  gone,

  /// A pessoa perdeu a permissão de editar.
  forbidden,
}

class SyncNotice {
  const SyncNotice({
    required this.id,
    required this.kind,
    required this.playlistId,
    required this.data,
  });

  factory SyncNotice.fromRow(SyncNoticeRow row) => SyncNotice(
    id: row.id,
    kind: SyncNoticeKind.values.byName(row.kind),
    playlistId: row.playlistId,
    data: jsonDecode(row.dataJson) as Map<String, dynamic>,
  );

  final int id;
  final SyncNoticeKind kind;
  final String playlistId;
  final Map<String, dynamic> data;

  String get name => data['name'] as String? ?? 'Playlist';
}

final syncNoticesProvider = StreamProvider<List<SyncNotice>>((ref) {
  final db = ref.watch(localDatabaseProvider);
  if (db == null) return Stream.value(const []);
  return db.watchNotices().map(
    (rows) => [for (final r in rows) SyncNotice.fromRow(r)],
  );
});

// ── Leitura: servidor (ou cópia) + alterações pendentes ─────────────

/// Lista do servidor; sem servidor, a última cópia. Grava a cópia.
final serverPlaylistsProvider = FutureProvider<List<ServerPlaylist>>((
  ref,
) async {
  final session = ref.watch(sessionProvider);
  if (!hasAccount(session)) return const [];
  final cache = ref.watch(playlistCacheProvider);
  if (session.canUseServer) {
    try {
      final list = await ref.read(playlistRepositoryProvider).myPlaylists();
      await cache?.saveList(list);
      return list;
    } on ApiException catch (e) {
      final copy = await cache?.list();
      if (copy == null || !e.isTransient) rethrow;
      return copy;
    }
  }
  return await cache?.list() ?? const [];
}, retry: _noRetry);

/// Lista da Biblioteca: servidor (ou cópia) com as alterações pendentes.
final myPlaylistsProvider = FutureProvider<List<ServerPlaylist>>((ref) async {
  final base = await ref.watch(serverPlaylistsProvider.future);
  final ops = await ref.watch(pendingPlaylistOpsProvider.future);
  return applyOpsToList(base, [
    for (final p in ops) p.op,
  ], me: _me(ref.read(sessionProvider)));
}, retry: _noRetry);

/// Detalhe do servidor; sem servidor, a cópia (ou a playlist baixada).
/// Nulo se não há nada no aparelho.
final serverPlaylistDetailProvider = FutureProvider.autoDispose
    .family<PlaylistDetail?, String>((ref, id) async {
      final session = ref.watch(sessionProvider);
      final cache = ref.watch(playlistCacheProvider);
      Future<PlaylistDetail?> local() async =>
          await cache?.detail(id) ??
          await ref.watch(offlinePlaylistProvider(id).future);
      if (session.canUseServer) {
        try {
          final detail = await ref.read(playlistRepositoryProvider).detail(id);
          await cache?.saveDetail(detail);
          return detail;
        } on ApiException catch (e) {
          if (!e.isTransient) rethrow;
          final copy = await local();
          if (copy == null) rethrow;
          return copy;
        }
      }
      return local();
    }, retry: _noRetry);

/// Detalhe com as alterações pendentes. [id] pode ser o ref temporário de
/// uma playlist criada offline (vale também depois que ela é enviada).
final playlistDetailProvider = FutureProvider.autoDispose
    .family<PlaylistDetail, String>((ref, id) async {
      final aliases = await ref.watch(playlistAliasesProvider.future);
      final realId = aliases[id] ?? id;
      final ops = [
        for (final p in await ref.watch(pendingPlaylistOpsProvider.future))
          p.op,
      ];
      final session = ref.read(sessionProvider);
      PlaylistDetail? base;
      if (PlaylistOp.isRef(realId)) {
        final create = ops
            .where((o) => o.type == PlaylistOpType.create && o.ref == realId)
            .firstOrNull;
        if (create != null) base = pendingPlaylist(create, owner: _me(session));
      } else {
        base = await ref.watch(serverPlaylistDetailProvider(realId).future);
      }
      if (base == null) throw const PlaylistUnavailable();
      final effective = applyOpsToDetail(base, ops, me: _me(session));
      if (effective == null) {
        throw const ApiException(ApiErrorKind.naoEncontrado, statusCode: 404);
      }
      return effective;
    }, retry: _noRetry);

/// A playlist não está no aparelho e não há servidor para buscar.
class PlaylistUnavailable implements Exception {
  const PlaylistUnavailable();
}

// ── Envio da fila ───────────────────────────────────────────────────

/// Resultado de um envio: quantas alterações foram aceitas e quantos
/// avisos novos surgiram.
class FlushOutcome {
  const FlushOutcome({this.sent = 0, this.notices = 0});

  final int sent;
  final int notices;
}

/// Envia a fila ao servidor. Estado: verdadeiro enquanto envia.
class PlaylistSync extends Notifier<bool> {
  static const batchSize = 50;

  Future<FlushOutcome>? _running;

  /// Avisa quando um envio gerou avisos novos (a tela mostra um toast).
  final _notices = StreamController<int>.broadcast();
  Stream<int> get newNotices => _notices.stream;

  @override
  bool build() {
    ref.onDispose(_notices.close);
    // Outra conta entrou neste aparelho: a cópia e a fila eram da anterior.
    ref.listen(sessionProvider.select((s) => s.username), (_, username) async {
      final cache = ref.read(playlistCacheProvider);
      if (username == null || cache == null) return;
      final owner = await cache.user();
      if (owner != null && owner != username) {
        await cache.clearAll();
        ref.invalidate(serverPlaylistsProvider);
        ref.invalidate(playlistAliasesProvider);
      }
    });
    return false;
  }

  Future<FlushOutcome> flush() => _running ??= _flush().whenComplete(() {
    _running = null;
    if (ref.mounted) state = false;
  });

  Future<FlushOutcome> _flush() async {
    final db = ref.read(localDatabaseProvider);
    final cache = ref.read(playlistCacheProvider);
    final session = ref.read(sessionProvider);
    if (db == null || cache == null || !session.canUseServer) {
      return const FlushOutcome();
    }
    state = true;
    var sent = 0;
    var notices = 0;
    while (true) {
      final rows = await db.playlistOpsInOrder();
      if (rows.isEmpty) break;
      final batch = rows.take(batchSize).toList();
      final ops = [
        for (final r in batch)
          PlaylistOp.fromJson(jsonDecode(r.opJson) as Map<String, dynamic>),
      ];
      final OpBatchResult result;
      try {
        result = await ref.read(playlistRepositoryProvider).applyOps(ops);
      } on ApiException catch (e) {
        // Sem rede ou servidor com problema: tudo fica para depois.
        debugPrint('Fila de playlists fica para depois: ${e.message}');
        break;
      }
      await cache.addAliases(result.refs);
      final byOp = {for (final r in result.results) r.opId: r};
      final done = <int>[];
      final failed =
          <String, List<PlaylistOp>>{}; // gone/forbidden por playlist
      final failedStatus = <String, OpStatus>{};
      for (final (i, op) in ops.indexed) {
        final r = byOp[op.opId];
        if (r == null || !r.status.isFinal) continue;
        done.add(batch[i].seq);
        switch (r.status) {
          case OpStatus.applied:
            sent++;
          case OpStatus.conflict:
            notices++;
            await _conflictNotice(db, op, r);
          case OpStatus.gone || OpStatus.forbidden:
            (failed[op.playlist] ??= []).add(op);
            failedStatus[op.playlist] = r.status;
          case OpStatus.invalid:
            debugPrint('Alteração recusada pelo servidor: ${r.message}');
          case OpStatus.retry:
            break;
        }
      }
      for (final MapEntry(key: playlistId, value: lost) in failed.entries) {
        notices++;
        await _lostNotice(
          db,
          cache,
          playlistId,
          lost,
          failedStatus[playlistId]!,
        );
      }
      await db.deletePlaylistOps(done);
      // Refs trocados pelos ids do servidor nas que ficaram na fila.
      if (result.refs.isNotEmpty) {
        for (final row in await db.playlistOpsInOrder()) {
          final op = PlaylistOp.fromJson(
            jsonDecode(row.opJson) as Map<String, dynamic>,
          ).remap(result.refs);
          await db.updatePlaylistOp(row.seq, op.playlist, jsonEncode(op));
        }
      }
      // Nada andou (só "retry"): tenta de novo na próxima vez.
      if (done.isEmpty) break;
    }
    ref.invalidate(playlistAliasesProvider);
    ref.invalidate(serverPlaylistsProvider);
    ref.invalidate(serverPlaylistDetailProvider);
    if (notices > 0) _notices.add(notices);
    return FlushOutcome(sent: sent, notices: notices);
  }

  Future<void> _conflictNotice(
    AppDatabase db,
    PlaylistOp op,
    OpResult r,
  ) async {
    final theirs = r.current?['name'] as String?;
    switch (op.type) {
      case PlaylistOpType.rename:
        await db.addNotice(
          SyncNoticeKind.renameConflict.name,
          r.playlistId ?? op.playlist,
          jsonEncode({'name': theirs, 'mine': op.name, 'theirs': theirs}),
        );
      case PlaylistOpType.delete:
        await db.addNotice(
          SyncNoticeKind.deleteConflict.name,
          r.playlistId ?? op.playlist,
          jsonEncode({
            'name': theirs,
            'track_count': r.current?['track_count'],
            'updated_at': r.current?['updated_at'],
          }),
        );
      default:
        break;
    }
  }

  /// Alterações perdidas (playlist apagada em outro lugar ou sem permissão).
  /// Guarda como a playlist ficaria, para "Recriar".
  Future<void> _lostNotice(
    AppDatabase db,
    PlaylistCache cache,
    String playlistId,
    List<PlaylistOp> lost,
    OpStatus status,
  ) async {
    final pending = [
      for (final r in await db.playlistOpsInOrder())
        PlaylistOp.fromJson(jsonDecode(r.opJson) as Map<String, dynamic>),
    ];
    final base =
        await cache.detail(playlistId) ??
        PlaylistDetail(id: playlistId, name: lost.first.name ?? 'Playlist');
    final snapshot = applyOpsToDetail(base, [
      ...lost,
      ...pending.where(
        (o) => o.playlist == playlistId && !lost.any((l) => l.opId == o.opId),
      ),
    ]);
    final name = snapshot?.name ?? base.name;
    await db.addNotice(
      status == OpStatus.gone
          ? SyncNoticeKind.gone.name
          : SyncNoticeKind.forbidden.name,
      playlistId,
      jsonEncode({
        'name': name,
        'count': lost.length,
        'tracks': [
          for (final t in snapshot?.tracks ?? const <PlaylistTrack>[])
            t.asResult.toJson(),
        ],
      }),
    );
    // Alterações seguintes da mesma playlist também não têm mais destino.
    await db.deletePlaylistOps([
      for (final r in await db.playlistOpsInOrder())
        if (r.playlistId == playlistId) r.seq,
    ]);
  }
}

final playlistSyncProvider = NotifierProvider<PlaylistSync, bool>(
  PlaylistSync.new,
);

// ── Edição (usada pelas telas) ──────────────────────────────────────

/// O servidor recusou a alteração na web (mudou em outro lugar).
class PlaylistConflict implements Exception {
  const PlaylistConflict(this.message);

  final String message;
}

class PlaylistEditor {
  PlaylistEditor(this._ref);

  final Ref _ref;

  PlaylistRepository get _repo => _ref.read(playlistRepositoryProvider);
  AppDatabase? get _db => _ref.read(localDatabaseProvider);

  /// Nova playlist. No app devolve o ref temporário (a tela abre na hora,
  /// mesmo sem servidor); na web, o id do servidor.
  Future<String> create(String name) async {
    final op = PlaylistOp.create(ref: PlaylistOp.newRef(), name: name.trim());
    final result = await _submit([op]);
    return result?.refs[op.ref] ?? op.ref!;
  }

  Future<void> rename(
    String playlistId, {
    required String name,
    required String current,
  }) async {
    if (name.trim() == current) return;
    await _submit([
      PlaylistOp.rename(playlistId, name: name.trim(), base: current),
    ]);
  }

  /// Uma faixa ou várias (link importado). Com servidor e muitas faixas, o
  /// servidor adiciona em segundo plano (mais rápido); senão, entram na fila.
  Future<void> addTracks(String playlistId, List<SearchResult> tracks) async {
    if (tracks.isEmpty) return;
    final online = _ref.read(sessionProvider).canUseServer;
    final pending = _ref.read(pendingPlaylistIdsProvider);
    if (tracks.length > 1 &&
        online &&
        !PlaylistOp.isRef(playlistId) &&
        !pending.contains(playlistId)) {
      try {
        await _repo.addTracks(playlistId, tracks);
        _refresh();
        return;
      } on ApiException catch (e) {
        if (_db == null || !e.isTransient) rethrow;
      }
    }
    await _submit([for (final t in tracks) PlaylistOp.add(playlistId, t)]);
  }

  Future<void> removeTrack(String playlistId, String trackId) =>
      _submit([PlaylistOp.remove(playlistId, trackId)]);

  /// Nova ordem: só as faixas que mudaram de lugar viram "mover".
  Future<void> reorder(
    String playlistId,
    List<String> from,
    List<String> to,
  ) async {
    final moves = movesFor(from, to);
    if (moves.isEmpty) return;
    await _submit([
      for (final m in moves)
        PlaylistOp.move(playlistId, m.track, after: m.after, before: m.before),
    ]);
  }

  /// [updatedAt]: versão que a pessoa estava vendo (detecta conflito).
  Future<void> delete(String playlistId, {String? updatedAt}) =>
      _submit([PlaylistOp.delete(playlistId, baseUpdatedAt: updatedAt)]);

  // ── Decisões dos avisos ──

  Future<void> keepServerVersion(SyncNotice notice) => _dismiss(notice);

  /// "Usar o meu nome" / "Apagar mesmo assim" / "Recriar".
  Future<void> applyMine(SyncNotice notice) async {
    switch (notice.kind) {
      case SyncNoticeKind.renameConflict:
        await _submit([
          PlaylistOp.rename(
            notice.playlistId,
            name: notice.data['mine'] as String,
            force: true,
          ),
        ]);
      case SyncNoticeKind.deleteConflict:
        await _submit([PlaylistOp.delete(notice.playlistId, force: true)]);
      case SyncNoticeKind.gone:
        final create = PlaylistOp.create(
          ref: PlaylistOp.newRef(),
          name: notice.name,
        );
        await _submit([
          create,
          for (final t in notice.data['tracks'] as List<dynamic>)
            PlaylistOp.add(
              create.ref!,
              SearchResult.fromJson(t as Map<String, dynamic>),
            ),
        ]);
      case SyncNoticeKind.forbidden:
        break;
    }
    await _dismiss(notice);
  }

  Future<void> _dismiss(SyncNotice notice) async =>
      _db?.deleteNotice(notice.id);

  /// App: entra na fila e envia se houver servidor. Web: envia direto.
  Future<OpBatchResult?> _submit(List<PlaylistOp> ops) async {
    final db = _db;
    if (db == null) {
      final result = await _repo.applyOps(ops);
      _refresh();
      final problem = result.results
          .where((r) => r.status != OpStatus.applied)
          .firstOrNull;
      if (problem != null) {
        throw PlaylistConflict(switch (problem.status) {
          OpStatus.conflict =>
            'A playlist mudou em outro lugar. A tela foi atualizada.',
          OpStatus.gone => 'Esta playlist não existe mais.',
          OpStatus.forbidden => 'Você não pode alterar esta playlist.',
          _ => 'Não foi possível salvar. Tente de novo.',
        });
      }
      return result;
    }
    final session = _ref.read(sessionProvider);
    await _ref.read(playlistCacheProvider)!.setUser(session.username ?? '');
    for (final op in ops) {
      await db.addPlaylistOp(op.playlist, jsonEncode(op));
    }
    if (session.canUseServer) {
      unawaited(_ref.read(playlistSyncProvider.notifier).flush());
    }
    return null;
  }

  void _refresh() {
    _ref.invalidate(serverPlaylistsProvider);
    _ref.invalidate(serverPlaylistDetailProvider);
  }
}

final playlistEditorProvider = Provider<PlaylistEditor>(PlaylistEditor.new);
