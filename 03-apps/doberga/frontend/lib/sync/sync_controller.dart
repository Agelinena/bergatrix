import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../auth/session.dart';
import '../data/models.dart';
import '../local/local_store.dart';
import 'sync_engine.dart';

/// Versão do protocolo de sync que este app fala (backend: SYNC_PROTOCOL).
const syncProtocol = 1;

const _uuid = Uuid();

/// UUIDv7: ordenado no tempo, gerado no aparelho.
String newId() => _uuid.v7();

/// Banco local da pessoa logada. Troca de pessoa = outro banco.
final localStoreProvider = FutureProvider<LocalStore>((ref) async {
  final userId = ref.watch(sessionProvider.select((s) => s.user?.id));
  if (userId == null) throw StateError('Sem sessão');
  final store = await openLocalStore(userId);
  ref.onDispose(store.close);
  return store;
});

/// O banco já aberto (as telas de dentro do app só existem depois disso).
final storeProvider = Provider<LocalStore>(
  (ref) => ref.watch(localStoreProvider).requireValue,
);

/// Relê [read] a cada mudança nas [tables] do banco local.
Stream<T> watchStore<T>(LocalStore store, Set<String> tables, T Function() read) async* {
  yield read();
  await for (final changed in store.changes) {
    if (changed.any(tables.contains)) yield read();
  }
}

final spacesProvider = StreamProvider<List<Space>>((ref) {
  final store = ref.watch(storeProvider);
  return watchStore(store, {'spaces'}, store.spaces);
});

final noticesProvider = StreamProvider<List<SyncNotice>>((ref) {
  final store = ref.watch(storeProvider);
  return watchStore(store, {'notices'}, store.notices);
});

class HttpSyncApi implements SyncApi {
  HttpSyncApi(this.dio);

  final Dio dio;

  static final _headers = Options(headers: {'X-Doberga-Sync': '$syncProtocol'});

  @override
  Future<List<Json>> push(String deviceId, List<Json> ops) async {
    final r = await _call(() => dio.post<Json>(
      '/api/sync/push',
      data: {'device_id': deviceId, 'ops': ops},
      options: _headers,
    ));
    return [for (final x in r['results'] as List) x as Json];
  }

  @override
  Future<Json> pull(Map<String, int> cursors) => _call(() => dio.post<Json>(
    '/api/sync/pull',
    data: {'cursors': cursors},
    options: _headers,
  ));

  Future<Json> _call(Future<Response<Json>> Function() request) async {
    try {
      return (await request()).data!;
    } on DioException catch (e) {
      if (e.response?.statusCode == 426) throw const SyncUpgradeRequired();
      rethrow;
    }
  }
}

enum SyncPhase { idle, syncing, offline, upgradeRequired, error }

class SyncStatus {
  const SyncStatus({
    this.phase = SyncPhase.idle,
    this.pending = 0,
    this.lastSync,
    this.error,
  });

  final SyncPhase phase;

  /// Alterações ainda no aparelho.
  final int pending;
  final DateTime? lastSync;
  final String? error;

  SyncStatus copyWith({SyncPhase? phase, int? pending, DateTime? lastSync, String? error}) =>
      SyncStatus(
        phase: phase ?? this.phase,
        pending: pending ?? this.pending,
        lastSync: lastSync ?? this.lastSync,
        error: error,
      );
}

/// Decide quando sincronizar: ao abrir, 2 s depois de uma alteração local,
/// quando a conexão volta, quando o servidor avisa (SSE) e a cada 5 min.
final syncProvider = NotifierProvider<SyncController, SyncStatus>(SyncController.new);

class SyncController extends Notifier<SyncStatus> {
  static const debounce = Duration(seconds: 2);
  static const period = Duration(minutes: 5);

  late SyncEngine _engine;
  late LocalStore _store;
  Timer? _debounce;
  Timer? _periodic;
  Timer? _retry;
  StreamSubscription<Set<String>>? _changes;
  StreamSubscription<List<ConnectivityResult>>? _connectivity;
  _EventStream? _events;
  int _failures = 0;

  @override
  SyncStatus build() {
    _store = ref.watch(storeProvider);
    var deviceId = _store.meta('device_id');
    if (deviceId == null) {
      deviceId = newId();
      _store.setMeta('device_id', deviceId);
    }
    _engine = SyncEngine(_store, HttpSyncApi(ref.watch(dioProvider)), deviceId: deviceId);

    _changes = _store.changes.listen((tables) {
      if (tables.contains('outbox')) _setPending();
    });
    _connectivity = Connectivity().onConnectivityChanged.listen((results) {
      if (!results.contains(ConnectivityResult.none)) syncNow();
    });
    _periodic = Timer.periodic(period, (_) => syncNow());
    _events = _EventStream(
      dio: ref.watch(dioProvider),
      deviceId: deviceId,
      onChange: syncNow,
    )..start();

    ref.onDispose(() {
      _debounce?.cancel();
      _periodic?.cancel();
      _retry?.cancel();
      _changes?.cancel();
      _connectivity?.cancel();
      _events?.stop();
    });

    Future.microtask(syncNow);
    final last = _store.meta('last_sync');
    return SyncStatus(
      pending: _store.pendingCount,
      lastSync: last == null ? null : DateTime.tryParse(last)?.toLocal(),
    );
  }

  void _setPending() {
    if (state.pending != _store.pendingCount) {
      state = state.copyWith(pending: _store.pendingCount, phase: state.phase, error: state.error);
    }
  }

  /// Chamado depois de cada alteração local.
  void schedule() {
    _setPending();
    _debounce?.cancel();
    _debounce = Timer(debounce, syncNow);
  }

  Future<void> syncNow() async {
    if (state.phase == SyncPhase.upgradeRequired) return;
    _retry?.cancel();
    state = state.copyWith(phase: SyncPhase.syncing);
    try {
      await _engine.sync();
      _failures = 0;
      state = SyncStatus(
        phase: SyncPhase.idle,
        pending: _store.pendingCount,
        lastSync: DateTime.now(),
      );
    } on SyncUpgradeRequired {
      state = state.copyWith(
        phase: SyncPhase.upgradeRequired,
        pending: _store.pendingCount,
        error: 'Atualize o Doberga para continuar sincronizando.',
      );
    } on DioException catch (e) {
      final offline = e.response == null;
      _failures++;
      state = state.copyWith(
        phase: offline ? SyncPhase.offline : SyncPhase.error,
        pending: _store.pendingCount,
        error: offline ? null : describeSyncError(e),
      );
      // Tenta de novo com espera crescente (até 5 min).
      final wait = Duration(seconds: (5 * (1 << _failures.clamp(0, 6))).clamp(5, 300));
      _retry = Timer(wait, syncNow);
    } on Object catch (e) {
      state = state.copyWith(phase: SyncPhase.error, pending: _store.pendingCount, error: '$e');
    }
  }
}

String describeSyncError(DioException e) {
  final data = e.response?.data;
  if (data is Map && data['detail'] is String) return data['detail'] as String;
  return 'O servidor respondeu ${e.response?.statusCode}.';
}

/// Grava no banco local e agenda o envio. É assim que todo módulo escreve.
final writerProvider = Provider<LocalWriter>(
  (ref) => LocalWriter(ref.watch(storeProvider), () => ref.read(syncProvider.notifier).schedule()),
);

class LocalWriter {
  LocalWriter(this.store, this.onWrite);

  final LocalStore store;
  final void Function() onWrite;

  /// Cria (com [spaceId]) ou altera só os [fields] informados.
  String upsert(String table, Json fields, {String? id, String? spaceId}) {
    final rowId = id ?? newId();
    store.applyLocal(
      table: table,
      rowId: rowId,
      kind: 'upsert',
      fields: fields,
      opId: newId(),
      spaceId: spaceId,
    );
    onWrite();
    return rowId;
  }

  void delete(String table, String id) {
    store.applyLocal(table: table, rowId: id, kind: 'delete', fields: const {}, opId: newId());
    onWrite();
  }
}

/// SSE `/api/sync/events`: o servidor avisa "algo mudou" e o app faz pull.
/// Na web o dio não entrega o corpo aos poucos, então lá o aviso é por
/// consulta a cada 30 s.
class _EventStream {
  _EventStream({required this.dio, required this.deviceId, required this.onChange});

  final Dio dio;
  final String deviceId;
  final void Function() onChange;

  bool _stopped = false;
  CancelToken? _cancel;
  Timer? _poll;

  void start() {
    if (kIsWeb) {
      _poll = Timer.periodic(const Duration(seconds: 30), (_) => onChange());
      return;
    }
    unawaited(_run());
  }

  void stop() {
    _stopped = true;
    _poll?.cancel();
    _cancel?.cancel();
  }

  Future<void> _run() async {
    var failures = 0;
    while (!_stopped) {
      _cancel = CancelToken();
      try {
        final r = await dio.get<ResponseBody>(
          '/api/sync/events',
          cancelToken: _cancel,
          options: Options(
            responseType: ResponseType.stream,
            receiveTimeout: const Duration(seconds: 60),
          ),
        );
        failures = 0;
        var event = '';
        await for (final line in r.data!.stream
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
          if (line.startsWith('event:')) {
            event = line.substring(6).trim();
          } else if (line.startsWith('data:') && event != 'hello') {
            _handle(event, line.substring(5).trim());
          } else if (line.isEmpty) {
            event = '';
          }
        }
      } on Object {
        failures++;
      }
      if (_stopped) break;
      // A conexão acaba sozinha quando o token vence; reconecta logo. Com
      // falha, espera mais a cada vez (até 1 min).
      await Future<void>.delayed(Duration(seconds: failures == 0 ? 1 : (5 * failures).clamp(5, 60)));
    }
  }

  void _handle(String event, String data) {
    try {
      final message = jsonDecode(data) as Map<String, dynamic>;
      if (event == 'changed' && message['origin'] == deviceId) return;
    } on Object {
      // aviso sem JSON: sincroniza do mesmo jeito
    }
    onChange();
  }
}
