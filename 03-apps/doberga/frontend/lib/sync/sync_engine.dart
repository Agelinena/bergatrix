import 'dart:async';

import '../data/models.dart';
import '../local/local_store.dart';

/// Conversa com o servidor (`/api/sync/push` e `/pull`). Em Dart puro, para
/// os testes usarem um servidor falso.
abstract interface class SyncApi {
  Future<List<Json>> push(String deviceId, List<Json> ops);
  Future<Json> pull(Map<String, int> cursors);
}

/// O servidor não aceita mais esta versão do app.
class SyncUpgradeRequired implements Exception {
  const SyncUpgradeRequired();
}

class SyncReport {
  const SyncReport({this.sent = 0, this.rejected = 0, this.received = 0});

  final int sent;
  final int rejected;
  final int received;
}

/// Envia a fila e busca o que mudou (protocolo em docs/ARQUITETURA.md).
///
/// - Push antes de pull, em lotes. Operação `ok` sai da fila; `rejected` sai
///   da fila e vira aviso, e a linha é refeita pelo pull.
/// - Pull: espaços que sumiram são apagados do aparelho; espaço em `reset` é
///   refeito do zero (mantendo o que está na fila). Cada linha que chega
///   recebe por cima as operações da fila ainda não enviadas ([rebase]).
/// - Uma chamada de cada vez; um pedido durante a sincronização marca outra
///   rodada logo depois.
class SyncEngine {
  SyncEngine(this.store, this.api, {required this.deviceId});

  final LocalStore store;
  final SyncApi api;
  final String deviceId;

  static const pushBatch = 200;

  Future<SyncReport>? _running;
  bool _again = false;

  Future<SyncReport> sync() {
    if (_running != null) {
      _again = true;
      return _running!;
    }
    return _running = _loop().whenComplete(() => _running = null);
  }

  Future<SyncReport> _loop() async {
    var total = const SyncReport();
    do {
      _again = false;
      final pushed = await _push();
      final received = await _pull();
      total = SyncReport(
        sent: total.sent + pushed.sent,
        rejected: total.rejected + pushed.rejected,
        received: total.received + received,
      );
    } while (_again);
    return total;
  }

  Future<SyncReport> _push() async {
    var sent = 0, rejected = 0;
    while (true) {
      final batch = store.pending(limit: pushBatch);
      if (batch.isEmpty) break;
      final results = await api.push(deviceId, [for (final op in batch) op.toJson()]);
      final done = <String>[];
      for (final r in results) {
        final opId = r['op_id'] as String;
        done.add(opId);
        if (r['status'] == 'rejected') {
          rejected++;
          final op = batch.firstWhere((o) => o.opId == opId, orElse: () => batch.first);
          store.addNotice(_rejectedMessage(op, r));
        } else {
          sent++;
        }
      }
      if (done.isEmpty) break;
      store.removeOps(done);
      if (batch.length < pushBatch) break;
    }
    return SyncReport(sent: sent, rejected: rejected);
  }

  String _rejectedMessage(PendingOp op, Json result) {
    final name = store.row(op.table, op.rowId)?.data;
    final label = (name?['name'] ?? name?['title']) as String?;
    final what = label != null && label.isNotEmpty ? '"$label"' : 'uma alteração';
    final why = result['message'] as String? ?? 'recusado pelo servidor';
    return 'Não deu para salvar $what: $why';
  }

  Future<int> _pull() async {
    var received = 0;
    var first = true;
    while (true) {
      final data = await api.pull(store.cursors());
      final spaces = [for (final s in data['spaces'] as List) Space.fromJson(s as Json)];
      final ids = {for (final s in spaces) s.id};
      if (first) {
        first = false;
        final known = {
          ...store.cursors().keys,
          for (final s in store.spaces()) s.id,
        };
        for (final gone in known.difference(ids)) {
          store.purgeSpace(gone);
        }
        for (final reset in (data['reset'] as List? ?? const [])) {
          store.purgeSpace(reset as String, keepPending: true);
        }
        store.setSpaces(spaces);
      }
      final rows = [
        for (final c in data['changes'] as List)
          _row((c as Json)['table'] as String, c['row'] as Json),
      ];
      store.applyRemote(rows, rebase);
      received += rows.length;
      store.setCursors({
        for (final e in (data['cursors'] as Json).entries) e.key: (e.value as num).toInt(),
      });
      if (data['has_more'] != true) break;
    }
    store.setMeta('last_sync', DateTime.now().toUtc().toIso8601String());
    return received;
  }

  LocalRow _row(String table, Json data) => LocalRow(
    table: table,
    id: data['id'] as String,
    spaceId: data['space_id'] as String,
    rev: (data['rev'] as num).toInt(),
    data: data,
  );

  /// A linha do servidor com as alterações locais ainda na fila por cima,
  /// na ordem em que foram feitas.
  Json rebase(LocalRow remote) {
    final data = Map<String, dynamic>.of(remote.data);
    for (final op in store.pending(limit: 1 << 30)) {
      if (op.table != remote.table || op.rowId != remote.id) continue;
      if (op.kind == 'delete') {
        data['deleted_at'] ??= DateTime.now().toUtc().toIso8601String();
      } else {
        for (final e in op.fields.entries) {
          if (e.key != 'space_id') data[e.key] = e.value;
        }
      }
    }
    return data;
  }
}
