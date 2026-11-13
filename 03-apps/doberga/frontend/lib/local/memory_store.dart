import 'dart:convert';

import '../data/models.dart';
import 'local_store.dart';

/// Banco local em memória, com todas as regras. A web usa este direto; o
/// SQLite (`local_store_io.dart`) herda dele e grava cada mudança em disco
/// pelos ganchos `persist*`, dentro de [transaction].
class MemoryLocalStore extends LocalStore with ChangeNotifierMixin {
  MemoryLocalStore({this.userId});

  /// Quem usa o app (created_by das linhas novas).
  final String? userId;

  final Map<String, Map<String, LocalRow>> _rows = {};
  final List<PendingOp> _ops = [];
  final Map<String, String> _meta = {};
  final List<SyncNotice> _notices = [];
  int _seq = 0;
  int _noticeSeq = 0;

  static const _cursorsKey = 'cursors';
  static const _spacesKey = 'spaces';

  // ── Ganchos de persistência (SQLite) ──

  /// Roda [body] de forma atômica (no SQLite, numa transação).
  T transaction<T>(T Function() body) => body();
  void persistRow(LocalRow row) {}
  void persistRowDelete(String table, String id) {}
  void persistOp(PendingOp op) {}
  void persistOpsDelete(Iterable<String> opIds) {}
  void persistMeta(String key, String? value) {}
  void persistNotice(SyncNotice notice) {}
  void persistNoticesClear() {}

  /// Carga inicial (SQLite).
  void load({
    required Iterable<LocalRow> rows,
    required Iterable<PendingOp> ops,
    required Map<String, String> meta,
    required Iterable<SyncNotice> notices,
  }) {
    for (final r in rows) {
      (_rows[r.table] ??= {})[r.id] = r;
    }
    _ops.addAll(ops);
    if (_ops.isNotEmpty) _seq = _ops.map((o) => o.seq).reduce((a, b) => a > b ? a : b);
    _meta.addAll(meta);
    _notices.addAll(notices);
    if (_notices.isNotEmpty) {
      _noticeSeq = _notices.map((n) => n.id).reduce((a, b) => a > b ? a : b);
    }
  }

  // ── Linhas ──

  @override
  List<LocalRow> rows(String table, {String? spaceId, bool includeDeleted = false}) => [
    for (final r in (_rows[table]?.values ?? const <LocalRow>[]))
      if ((spaceId == null || r.spaceId == spaceId) && (includeDeleted || !r.deleted)) r,
  ];

  @override
  LocalRow? row(String table, String id) => _rows[table]?[id];

  void _put(LocalRow row) {
    (_rows[row.table] ??= {})[row.id] = row;
    persistRow(row);
  }

  void _drop(String table, String id) {
    if (_rows[table]?.remove(id) != null) persistRowDelete(table, id);
  }

  @override
  void applyLocal({
    required String table,
    required String rowId,
    required String kind,
    required Json fields,
    required String opId,
    String? spaceId,
  }) {
    transaction(() {
      final current = row(table, rowId);
      final now = DateTime.now().toUtc().toIso8601String();
      if (kind == 'delete') {
        if (current == null) return;
        _put(LocalRow(
          table: table,
          id: rowId,
          spaceId: current.spaceId,
          rev: current.rev,
          data: {...current.data, 'deleted_at': now},
        ));
      } else {
        final space = current?.spaceId ?? spaceId ?? fields['space_id'] as String?;
        if (space == null) {
          throw ArgumentError('Linha nova precisa do espaço (space_id)');
        }
        final base = current?.data ??
            {
              'id': rowId,
              'space_id': space,
              'rev': 0,
              'created_at': now,
              'created_by': userId,
              'deleted_at': null,
            };
        _put(LocalRow(
          table: table,
          id: rowId,
          spaceId: space,
          rev: current?.rev ?? 0,
          data: {
            ...base,
            ...fields,
            'space_id': space,
            'updated_at': now,
            'updated_by': userId,
          },
        ));
        if (current == null) fields = {...fields, 'space_id': space};
      }
      final op = PendingOp(
        seq: ++_seq,
        opId: opId,
        table: table,
        rowId: rowId,
        kind: kind,
        fields: fields,
        baseRev: current?.rev,
      );
      _ops.add(op);
      persistOp(op);
    });
    notify({table});
  }

  @override
  void applyRemote(List<LocalRow> remote, Json Function(LocalRow row) rebase) {
    if (remote.isEmpty) return;
    final touched = <String>{};
    transaction(() {
      for (final r in remote) {
        touched.add(r.table);
        if (r.deleted) {
          _drop(r.table, r.id);
          continue;
        }
        _put(LocalRow(
          table: r.table,
          id: r.id,
          spaceId: r.spaceId,
          rev: r.rev,
          data: rebase(r),
        ));
      }
    });
    notify(touched);
  }

  @override
  void purgeSpace(String spaceId, {bool keepPending = false}) {
    final keep = keepPending ? {for (final o in _ops) '${o.table}/${o.rowId}'} : <String>{};
    final touched = <String>{};
    transaction(() {
      // As operações primeiro: o espaço delas vem da linha, que vai sumir.
      final gone = keepPending
          ? const <String>[]
          : [
              for (final o in _ops)
                if (o.fields['space_id'] == spaceId || _spaceOfOp(o) == spaceId) o.opId,
            ];
      for (final entry in _rows.entries) {
        final ids = [
          for (final r in entry.value.values)
            if (r.spaceId == spaceId && !keep.contains('${r.table}/${r.id}')) r.id,
        ];
        for (final id in ids) {
          _drop(entry.key, id);
          touched.add(entry.key);
        }
      }
      touched.addAll(_removeOps(gone));
    });
    notify(touched);
  }

  String? _spaceOfOp(PendingOp op) => row(op.table, op.rowId)?.spaceId;

  // ── Fila ──

  @override
  List<PendingOp> pending({int limit = 1000}) => _ops.take(limit).toList();

  @override
  int get pendingCount => _ops.length;

  @override
  void removeOps(Iterable<String> opIds) {
    final touched = <String>{};
    transaction(() => touched.addAll(_removeOps(opIds)));
    notify(touched);
  }

  /// Tira da fila. Uma exclusão confirmada também sai do banco local (o
  /// servidor pode nunca mandar a lápide: a linha talvez nem tenha chegado lá).
  Set<String> _removeOps(Iterable<String> opIds) {
    final ids = opIds.toSet();
    if (ids.isEmpty) return const {};
    final touched = <String>{};
    final removed = _ops.where((o) => ids.contains(o.opId)).toList();
    _ops.removeWhere((o) => ids.contains(o.opId));
    persistOpsDelete(ids);
    for (final op in removed) {
      final current = row(op.table, op.rowId);
      final stillPending = _ops.any((o) => o.table == op.table && o.rowId == op.rowId);
      if (op.kind == 'delete' && current != null && current.deleted && !stillPending) {
        _drop(op.table, op.rowId);
        touched.add(op.table);
      }
    }
    touched.add('outbox');
    return touched;
  }

  // ── Cursores e espaços ──

  @override
  Map<String, int> cursors() {
    final raw = _meta[_cursorsKey];
    if (raw == null) return {};
    return {
      for (final e in decodeJson(raw).entries) e.key: (e.value as num).toInt(),
    };
  }

  @override
  void setCursors(Map<String, int> cursors) => setMeta(_cursorsKey, encodeJson(cursors));

  @override
  List<Space> spaces() {
    final raw = _meta[_spacesKey];
    if (raw == null) return const [];
    return [for (final s in jsonDecode(raw) as List) Space.fromJson(s as Json)];
  }

  @override
  void setSpaces(List<Space> spaces) {
    setMeta(_spacesKey, encodeJson([for (final s in spaces) s.toJson()]));
    notify({'spaces'});
  }

  // ── Avisos ──

  @override
  void addNotice(String message) {
    final notice = SyncNotice(id: ++_noticeSeq, message: message, at: DateTime.now());
    _notices.add(notice);
    persistNotice(notice);
    notify({'notices'});
  }

  @override
  List<SyncNotice> notices() => List.unmodifiable(_notices);

  @override
  void clearNotices() {
    _notices.clear();
    persistNoticesClear();
    notify({'notices'});
  }

  // ── Chave/valor ──

  @override
  String? meta(String key) => _meta[key];

  @override
  void setMeta(String key, String? value) {
    if (value == null) {
      _meta.remove(key);
    } else {
      _meta[key] = value;
    }
    persistMeta(key, value);
  }

  @override
  Future<void> close() => closeChanges();
}
