import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import 'local_store.dart';
import 'memory_store.dart';

/// Android, Windows, Linux: SQLite em arquivo, um por pessoa
/// (`doberga_<id>.db` na pasta de dados do app). As leituras saem da memória
/// (carregada ao abrir); cada gravação vai para o disco na mesma transação.
Future<LocalStore> openLocalStore(String userId) async {
  final dir = await getApplicationSupportDirectory();
  await dir.create(recursive: true);
  final safe = userId.replaceAll(RegExp(r'[^A-Za-z0-9-]'), '');
  return SqliteLocalStore.open(p.join(dir.path, 'doberga_$safe.db'), userId);
}

class SqliteLocalStore extends MemoryLocalStore {
  SqliteLocalStore._(this._db, String userId) : super(userId: userId);

  final Database _db;
  int _depth = 0;
  bool _closed = false;

  static const schemaVersion = 1;

  factory SqliteLocalStore.open(String path, String userId) {
    final db = sqlite3.open(path);
    db.execute('PRAGMA journal_mode = WAL');
    db.execute('PRAGMA synchronous = NORMAL');
    _migrate(db);
    final store = SqliteLocalStore._(db, userId);
    store.load(
      rows: [
        for (final r in db.select('SELECT tbl, id, space_id, rev, data FROM rows'))
          LocalRow(
            table: r['tbl'] as String,
            id: r['id'] as String,
            spaceId: r['space_id'] as String,
            rev: r['rev'] as int,
            data: decodeJson(r['data'] as String),
          ),
      ],
      ops: [
        for (final r in db.select(
          'SELECT seq, op_id, tbl, row_id, kind, fields, base_rev FROM outbox ORDER BY seq',
        ))
          PendingOp(
            seq: r['seq'] as int,
            opId: r['op_id'] as String,
            table: r['tbl'] as String,
            rowId: r['row_id'] as String,
            kind: r['kind'] as String,
            fields: decodeJson(r['fields'] as String),
            baseRev: r['base_rev'] as int?,
          ),
      ],
      meta: {
        for (final r in db.select('SELECT key, value FROM meta'))
          r['key'] as String: r['value'] as String,
      },
      notices: [
        for (final r in db.select('SELECT id, message, at FROM notices ORDER BY id'))
          SyncNotice(
            id: r['id'] as int,
            message: r['message'] as String,
            at: DateTime.parse(r['at'] as String),
          ),
      ],
    );
    return store;
  }

  static void _migrate(Database db) {
    final version = db.select('PRAGMA user_version').first.columnAt(0) as int;
    if (version < 1) {
      db.execute('''
        CREATE TABLE IF NOT EXISTS rows (
          tbl TEXT NOT NULL,
          id TEXT NOT NULL,
          space_id TEXT NOT NULL,
          rev INTEGER NOT NULL,
          data TEXT NOT NULL,
          PRIMARY KEY (tbl, id)
        );
        CREATE INDEX IF NOT EXISTS rows_space ON rows (space_id);
        CREATE TABLE IF NOT EXISTS outbox (
          seq INTEGER PRIMARY KEY,
          op_id TEXT NOT NULL UNIQUE,
          tbl TEXT NOT NULL,
          row_id TEXT NOT NULL,
          kind TEXT NOT NULL,
          fields TEXT NOT NULL,
          base_rev INTEGER
        );
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS notices (
          id INTEGER PRIMARY KEY,
          message TEXT NOT NULL,
          at TEXT NOT NULL
        );
      ''');
    }
    db.execute('PRAGMA user_version = $schemaVersion');
  }

  @override
  T transaction<T>(T Function() body) {
    if (_depth > 0) return body();
    _depth++;
    _db.execute('BEGIN IMMEDIATE');
    try {
      final result = body();
      _db.execute('COMMIT');
      return result;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    } finally {
      _depth--;
    }
  }

  @override
  void persistRow(LocalRow row) => _db.execute(
    'INSERT OR REPLACE INTO rows (tbl, id, space_id, rev, data) VALUES (?, ?, ?, ?, ?)',
    [row.table, row.id, row.spaceId, row.rev, encodeJson(row.data)],
  );

  @override
  void persistRowDelete(String table, String id) =>
      _db.execute('DELETE FROM rows WHERE tbl = ? AND id = ?', [table, id]);

  @override
  void persistOp(PendingOp op) => _db.execute(
    'INSERT INTO outbox (seq, op_id, tbl, row_id, kind, fields, base_rev) '
    'VALUES (?, ?, ?, ?, ?, ?, ?)',
    [op.seq, op.opId, op.table, op.rowId, op.kind, encodeJson(op.fields), op.baseRev],
  );

  @override
  void persistOpsDelete(Iterable<String> opIds) {
    for (final id in opIds) {
      _db.execute('DELETE FROM outbox WHERE op_id = ?', [id]);
    }
  }

  @override
  void persistMeta(String key, String? value) => value == null
      ? _db.execute('DELETE FROM meta WHERE key = ?', [key])
      : _db.execute('INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)', [key, value]);

  @override
  void persistNotice(SyncNotice notice) => _db.execute(
    'INSERT INTO notices (id, message, at) VALUES (?, ?, ?)',
    [notice.id, notice.message, notice.at.toIso8601String()],
  );

  @override
  void persistNoticesClear() => _db.execute('DELETE FROM notices');

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await super.close();
    _db.close();
  }
}

/// Usado só para apagar os dados locais de uma pessoa (sair e limpar).
Future<void> deleteLocalStore(String userId) async {
  final dir = await getApplicationSupportDirectory();
  final safe = userId.replaceAll(RegExp(r'[^A-Za-z0-9-]'), '');
  for (final suffix in ['', '-wal', '-shm']) {
    final file = File(p.join(dir.path, 'doberga_$safe.db$suffix'));
    if (await file.exists()) await file.delete();
  }
}
