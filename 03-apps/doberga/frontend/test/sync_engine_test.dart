import 'package:doberga/data/models.dart';
import 'package:doberga/local/local_store.dart';
import 'package:doberga/local/memory_store.dart';
import 'package:doberga/sync/sync_engine.dart';
import 'package:flutter_test/flutter_test.dart';

/// Servidor falso com as regras principais do real (backend/app/sync/engine.py):
/// rev global, atualização só dos campos enviados, lápides, op_id idempotente.
class FakeServer implements SyncApi {
  final Map<String, Map<String, dynamic>> rows = {};
  final Map<String, Map<String, dynamic>> applied = {};
  final List<Map<String, dynamic>> spaces = [
    {'id': 'p1', 'kind': 'personal', 'name': 'Pessoal', 'role': 'owner', 'members': []},
  ];
  int rev = 0;
  bool offline = false;
  int pushes = 0;

  @override
  Future<List<Json>> push(String deviceId, List<Json> ops) async {
    if (offline) throw Exception('offline');
    pushes++;
    return [
      for (final op in ops) applied[op['op_id'] as String] ??= _apply(op),
    ];
  }

  Json _apply(Json op) {
    final id = op['row_id'] as String;
    final fields = Map<String, dynamic>.of(op['fields'] as Json);
    final current = rows[id];
    if (op['kind'] == 'delete') {
      if (current != null && current['deleted_at'] == null) {
        current['deleted_at'] = 'x';
        current['rev'] = ++rev;
      }
      return {'op_id': op['op_id'], 'status': 'ok'};
    }
    if (current != null && current['deleted_at'] != null) {
      return {'op_id': op['op_id'], 'status': 'rejected', 'reason': 'deleted', 'message': 'Foi apagado'};
    }
    if (current == null) {
      rows[id] = {'id': id, 'deleted_at': null, ...fields, 'table': op['table'], 'rev': ++rev};
    } else {
      current.addAll(fields..remove('space_id'));
      current['rev'] = ++rev;
    }
    return {'op_id': op['op_id'], 'status': 'ok'};
  }

  @override
  Future<Json> pull(Map<String, int> cursors) async {
    if (offline) throw Exception('offline');
    final ids = {for (final s in spaces) s['id'] as String};
    final since = {for (final id in ids) id: cursors[id] ?? 0};
    final changes = [
      for (final r in rows.values.toList()..sort((a, b) => (a['rev'] as int).compareTo(b['rev'] as int)))
        if (ids.contains(r['space_id']) && (r['rev'] as int) > since[r['space_id']]!)
          {'table': r['table'], 'row': Map<String, dynamic>.of(r)..remove('table')},
    ];
    final top = changes.isEmpty ? null : (changes.last['row'] as Json)['rev'] as int;
    return {
      'spaces': spaces,
      'changes': changes,
      'cursors': {for (final e in since.entries) e.key: top == null ? e.value : (top > e.value ? top : e.value)},
      'reset': <String>[],
      'has_more': false,
    };
  }

  /// Outra pessoa grava direto no servidor.
  void remoteEdit(String id, Json fields) {
    rows[id]!.addAll(fields);
    rows[id]!['rev'] = ++rev;
  }
}

void main() {
  late FakeServer server;
  late MemoryLocalStore store;
  late SyncEngine engine;
  var opSeq = 0;

  String op() => 'op${opSeq++}';

  setUp(() {
    server = FakeServer();
    store = MemoryLocalStore(userId: 'u1');
    engine = SyncEngine(store, server, deviceId: 'd1');
  });

  test('criar offline e enviar depois', () async {
    server.offline = true;
    store.applyLocal(table: 'items', rowId: 'i1', kind: 'upsert',
        fields: {'name': 'Arroz', 'quantity': 2}, opId: op(), spaceId: 'p1');
    expect(store.rows('items').single.data['name'], 'Arroz');
    expect(store.pendingCount, 1);
    await expectLater(engine.sync(), throwsException);
    expect(store.pendingCount, 1, reason: 'sem conexão, a fila fica');

    server.offline = false;
    await engine.sync();
    expect(store.pendingCount, 0);
    expect(server.rows['i1']!['name'], 'Arroz');
    expect(server.rows['i1']!['space_id'], 'p1');
    expect(store.rows('items').single.rev, greaterThan(0));
  });

  test('alteração local não volta ao valor antigo antes de ser enviada', () async {
    store.applyLocal(table: 'items', rowId: 'i1', kind: 'upsert',
        fields: {'name': 'Banana', 'quantity': 6, 'state': 'pending'}, opId: op(), spaceId: 'p1');
    await engine.sync();
    // Offline, eu mudo a quantidade; outra pessoa marca no carrinho.
    store.applyLocal(table: 'items', rowId: 'i1', kind: 'upsert', fields: {'quantity': 12}, opId: op());
    server.remoteEdit('i1', {'state': 'in_cart'});
    final remote = Map<String, dynamic>.of(server.rows['i1']!)..remove('table');
    final rebased = engine.rebase(LocalRow(
      table: 'items', id: 'i1', spaceId: 'p1', rev: remote['rev'] as int, data: remote));
    expect(rebased['quantity'], 12, reason: 'a fila vale por cima do servidor');
    expect(rebased['state'], 'in_cart');
    await engine.sync();
    final row = store.row('items', 'i1')!.data;
    expect(row['quantity'], 12);
    expect(row['state'], 'in_cart');
  });

  test('editar algo apagado por outra pessoa vira aviso', () async {
    store.applyLocal(table: 'items', rowId: 'i1', kind: 'upsert',
        fields: {'name': 'Leite'}, opId: op(), spaceId: 'p1');
    await engine.sync();
    server.rows['i1']!
      ..['deleted_at'] = 'x'
      ..['rev'] = ++server.rev;
    store.applyLocal(table: 'items', rowId: 'i1', kind: 'upsert', fields: {'quantity': 3}, opId: op());
    final report = await engine.sync();
    expect(report.rejected, 1);
    expect(store.notices().single.message, contains('Leite'));
    expect(store.rows('items'), isEmpty, reason: 'a lápide do pull apaga a linha');
  });

  test('apagar algo que nunca chegou ao servidor some do aparelho', () async {
    server.offline = true;
    store.applyLocal(table: 'items', rowId: 'i9', kind: 'upsert',
        fields: {'name': 'Pão'}, opId: op(), spaceId: 'p1');
    store.applyLocal(table: 'items', rowId: 'i9', kind: 'delete', fields: const {}, opId: op());
    expect(store.rows('items'), isEmpty);
    server.offline = false;
    await engine.sync();
    expect(store.rows('items', includeDeleted: true), isEmpty);
    expect(store.pendingCount, 0);
  });

  test('sair de um grupo apaga os dados dele do aparelho', () async {
    server.spaces.add({'id': 'g1', 'kind': 'group', 'name': 'Casa', 'role': 'member', 'members': []});
    store.applyLocal(table: 'items', rowId: 'i1', kind: 'upsert',
        fields: {'name': 'Café'}, opId: op(), spaceId: 'g1');
    await engine.sync();
    expect(store.spaces().length, 2);
    server.spaces.removeLast();
    await engine.sync();
    expect(store.spaces().length, 1);
    expect(store.rows('items'), isEmpty);
  });

  test('reenvio depois de resposta perdida não duplica', () async {
    store.applyLocal(table: 'items', rowId: 'i1', kind: 'upsert',
        fields: {'name': 'Ovo'}, opId: 'fixo', spaceId: 'p1');
    final ops = [for (final o in store.pending()) o.toJson()];
    await server.push('d1', ops); // chegou, mas a resposta "se perdeu"
    final revBefore = server.rev;
    await engine.sync();
    expect(server.rev, revBefore, reason: 'o mesmo op_id não aplica de novo');
    expect(store.pendingCount, 0);
  });
}
