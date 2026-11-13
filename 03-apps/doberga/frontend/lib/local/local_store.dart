import 'dart:async';
import 'dart:convert';

import '../data/models.dart';
import 'local_store_io.dart'
    if (dart.library.js_interop) 'local_store_web.dart'
    as platform;

/// Uma linha de tabela sincronizada, como veio do servidor (ou como ficou
/// depois de uma alteração local ainda não enviada).
class LocalRow {
  const LocalRow({
    required this.table,
    required this.id,
    required this.spaceId,
    required this.rev,
    required this.data,
  });

  final String table;
  final String id;
  final String spaceId;

  /// rev do servidor; 0 para o que nasceu no aparelho e ainda não foi enviado.
  final int rev;

  /// Todas as colunas (padrão + do módulo), como no JSON do pull.
  final Json data;

  bool get deleted => data['deleted_at'] != null;
}

/// Operação na fila: o que ainda precisa chegar ao servidor.
class PendingOp {
  const PendingOp({
    required this.seq,
    required this.opId,
    required this.table,
    required this.rowId,
    required this.kind,
    required this.fields,
    this.baseRev,
  });

  final int seq;
  final String opId;
  final String table;
  final String rowId;

  /// `upsert` ou `delete`.
  final String kind;
  final Json fields;
  final int? baseRev;

  Json toJson() => {
    'op_id': opId,
    'table': table,
    'row_id': rowId,
    'kind': kind,
    'fields': fields,
    'base_rev': baseRev,
  };
}

/// Aviso de operação recusada pelo servidor (mostrado à pessoa).
class SyncNotice {
  const SyncNotice({required this.id, required this.message, required this.at});

  final int id;
  final String message;
  final DateTime at;
}

/// Banco local do aparelho: espelho das linhas, fila de operações, cursores e
/// a lista de espaços. Um banco por pessoa.
///
/// - Android, Windows, Linux: SQLite em arquivo ([platform.openLocalStore]).
/// - Web: memória (a web funciona online; nada fica no navegador).
///
/// As operações de escrita são síncronas e atômicas: [applyLocal] grava a
/// linha e a operação juntas, então um app fechado no meio nunca deixa uma
/// sem a outra.
abstract class LocalStore {
  /// Muda quando algo é gravado: o nome das tabelas afetadas
  /// (`spaces` para a lista de espaços).
  Stream<Set<String>> get changes;

  // ── Linhas ──
  List<LocalRow> rows(String table, {String? spaceId, bool includeDeleted = false});
  LocalRow? row(String table, String id);

  /// Alteração feita no aparelho: grava a linha e põe a operação na fila.
  void applyLocal({
    required String table,
    required String rowId,
    required String kind,
    required Json fields,
    required String opId,
    String? spaceId,
  });

  /// Linhas que vieram do servidor. [rebase] reaplica por cima as operações
  /// da fila (ver `SyncEngine`).
  void applyRemote(List<LocalRow> rows, Json Function(LocalRow row) rebase);

  /// Apaga tudo do espaço (saiu do grupo, ou o servidor pediu reset), exceto
  /// as linhas com operação na fila quando [keepPending].
  void purgeSpace(String spaceId, {bool keepPending = false});

  // ── Fila ──
  List<PendingOp> pending({int limit = 1000});
  int get pendingCount;
  void removeOps(Iterable<String> opIds);

  // ── Cursores e espaços ──
  Map<String, int> cursors();
  void setCursors(Map<String, int> cursors);
  List<Space> spaces();
  void setSpaces(List<Space> spaces);

  // ── Avisos ──
  void addNotice(String message);
  List<SyncNotice> notices();
  void clearNotices();

  // ── Chave/valor (último sync, id do aparelho) ──
  String? meta(String key);
  void setMeta(String key, String? value);

  Future<void> close();
}

/// Abre o banco local da pessoa.
Future<LocalStore> openLocalStore(String userId) =>
    platform.openLocalStore(userId);

/// Apaga o banco local da pessoa ("Sair e apagar os dados deste aparelho").
Future<void> deleteLocalStore(String userId) =>
    platform.deleteLocalStore(userId);

/// Parte comum: avisos de mudança.
mixin ChangeNotifierMixin {
  final _changes = StreamController<Set<String>>.broadcast();

  Stream<Set<String>> get changes => _changes.stream;

  void notify(Set<String> tables) {
    if (tables.isNotEmpty && !_changes.isClosed) _changes.add(tables);
  }

  Future<void> closeChanges() => _changes.close();
}

String encodeJson(Object? value) => jsonEncode(value);
Json decodeJson(String value) => jsonDecode(value) as Json;
