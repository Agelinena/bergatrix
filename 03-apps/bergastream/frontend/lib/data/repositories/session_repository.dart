import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/network/api_error.dart';
import '../api/api_dio.dart';
import '../models/playlist_models.dart';
import '../models/search_result.dart';

/// Sessão compartilhada ("ouvir junto"): todos ouvem a mesma coisa. O
/// servidor guarda o estado; cada aparelho toca o próprio áudio no ponto
/// certo (ver `backend/app/sessions/playback.py`).

/// Modo de pausa da sessão.
enum PauseMode {
  /// Pausar pausa para todo mundo.
  all('all', 'Pausar para todos'),

  /// Cada um pausa o seu; ao voltar, entra onde os outros estão.
  individual('individual', 'Cada um pausa o seu');

  const PauseMode(this.apiValue, this.label);

  final String apiValue;
  final String label;

  static PauseMode parse(String? value) =>
      value == 'individual' ? PauseMode.individual : PauseMode.all;
}

class SessionEntry {
  const SessionEntry({
    required this.uid,
    required this.track,
    this.addedBy,
    this.manual = false,
  });

  factory SessionEntry.fromJson(Map<String, dynamic> json) => SessionEntry(
    uid: json['uid'] as String,
    track: SearchResult.fromJson(json['track'] as Map<String, dynamic>),
    addedBy: json['added_by'] as String?,
    manual: json['manual'] as bool? ?? false,
  );

  final String uid;
  final SearchResult track;

  /// Username de quem pôs na fila.
  final String? addedBy;

  /// Veio de "Adicionar à fila" (e não da lista que está tocando).
  final bool manual;
}

/// Reprodução compartilhada. A posição é uma âncora: [positionMs] valia
/// no instante [anchorAt] (relógio do servidor).
class SessionPlayback {
  const SessionPlayback({
    this.queue = const [],
    this.index = -1,
    this.playing = false,
    this.positionMs = 0,
    this.anchorAt = 0,
    this.version = 0,
  });

  factory SessionPlayback.fromJson(Map<String, dynamic> json) =>
      SessionPlayback(
        queue: [
          for (final e in json['queue'] as List<dynamic>? ?? const [])
            SessionEntry.fromJson(e as Map<String, dynamic>),
        ],
        index: json['index'] as int? ?? -1,
        playing: json['playing'] as bool? ?? false,
        positionMs: json['position_ms'] as int? ?? 0,
        anchorAt: json['anchor_at'] as int? ?? 0,
        version: json['version'] as int? ?? 0,
      );

  final List<SessionEntry> queue;
  final int index;
  final bool playing;
  final int positionMs;
  final int anchorAt;
  final int version;

  SessionEntry? get current =>
      index >= 0 && index < queue.length ? queue[index] : null;

  /// Tamanho da fila manual logo depois da atual (toca antes do resto da
  /// lista, como "Sua fila" no modo normal).
  int get manualCount {
    var n = 0;
    for (var i = index + 1; i < queue.length && queue[i].manual; i++) {
      n++;
    }
    return n;
  }

  /// Onde a música deveria estar agora (relógio do servidor em ms).
  /// (Sem `1 << n` como limite: na web o deslocamento é de 32 bits e
  /// `1 << 40` vira 0, o que prendia a posição no começo.)
  Duration positionAt(int serverNowMs) => Duration(
    milliseconds: playing
        ? positionMs + math.max(0, serverNowMs - anchorAt)
        : positionMs,
  );
}

class SessionMember {
  const SessionMember({
    required this.user,
    required this.status,
    this.online = false,
  });

  factory SessionMember.fromJson(Map<String, dynamic> json) => SessionMember(
    user: Person.fromJson(json['user'] as Map<String, dynamic>),
    status: json['status'] as String,
    online: json['online'] as bool? ?? false,
  );

  final Person user;

  /// `invited` ou `joined`.
  final String status;
  final bool online;

  bool get joined => status == 'joined';
}

class SessionInfo {
  const SessionInfo({
    required this.id,
    required this.name,
    required this.owner,
    required this.pauseMode,
    this.members = const [],
    this.playback = const SessionPlayback(),
    this.serverNow = 0,
  });

  factory SessionInfo.fromJson(Map<String, dynamic> json) => SessionInfo(
    id: json['id'] as String,
    name: json['name'] as String? ?? '',
    owner: Person.fromJson(json['owner'] as Map<String, dynamic>),
    pauseMode: PauseMode.parse(json['pause_mode'] as String?),
    members: [
      for (final m in json['members'] as List<dynamic>? ?? const [])
        SessionMember.fromJson(m as Map<String, dynamic>),
    ],
    playback: SessionPlayback.fromJson(
      json['playback'] as Map<String, dynamic>? ?? const {},
    ),
    serverNow: json['server_now'] as int? ?? 0,
  );

  final String id;
  final String name;
  final Person owner;
  final PauseMode pauseMode;
  final List<SessionMember> members;
  final SessionPlayback playback;
  final int serverNow;

  SessionInfo copyWith({SessionPlayback? playback, PauseMode? pauseMode}) =>
      SessionInfo(
        id: id,
        name: name,
        owner: owner,
        pauseMode: pauseMode ?? this.pauseMode,
        members: members,
        playback: playback ?? this.playback,
        serverNow: serverNow,
      );

  /// Nome de quem tem este username (para "Marina pausou").
  String nameOf(String username) => members
      .map((m) => m.user)
      .followedBy([owner])
      .firstWhere(
        (p) => p.username == username,
        orElse: () => Person(id: '', username: username, name: username),
      )
      .name;

  List<SessionMember> get joined => [
    for (final m in members)
      if (m.joined) m,
  ];

  String get title => name.isNotEmpty ? name : 'Sessão de ${owner.name}';
}

class SessionInvite {
  const SessionInvite({
    required this.sessionId,
    required this.name,
    required this.owner,
    this.invitedBy,
  });

  factory SessionInvite.fromJson(Map<String, dynamic> json) => SessionInvite(
    sessionId: json['session_id'] as String,
    name: json['name'] as String? ?? '',
    owner: Person.fromJson(json['owner'] as Map<String, dynamic>),
    invitedBy: json['invited_by'] == null
        ? null
        : Person.fromJson(json['invited_by'] as Map<String, dynamic>),
  );

  final String sessionId;
  final String name;
  final Person owner;
  final Person? invitedBy;
}

class MySessions {
  const MySessions({this.current, this.invites = const []});

  factory MySessions.fromJson(Map<String, dynamic> json) => MySessions(
    current: json['current'] == null
        ? null
        : SessionInfo.fromJson(json['current'] as Map<String, dynamic>),
    invites: [
      for (final i in json['invites'] as List<dynamic>? ?? const [])
        SessionInvite.fromJson(i as Map<String, dynamic>),
    ],
  );

  final SessionInfo? current;
  final List<SessionInvite> invites;
}

/// Rotas REST das sessões. Lança [ApiException].
abstract interface class SessionRepository {
  Future<MySessions> mine();
  Future<SessionInfo> create({required String name, required PauseMode mode});
  Future<void> invite(String sessionId, List<String> userIds);
  Future<SessionInfo> join(String sessionId);
  Future<void> leave(String sessionId);
  Future<void> decline(String sessionId);
  Future<SessionInfo> update(String sessionId, {String? name, PauseMode? mode});
  Future<void> end(String sessionId);
  Future<void> kick(String sessionId, String userId);

  /// Ação na reprodução por HTTP (reserva quando a conexão em tempo real
  /// caiu).
  Future<SessionPlayback> act(String sessionId, Map<String, Object?> action);
}

class HttpSessionRepository implements SessionRepository {
  HttpSessionRepository(this._dio);

  final Dio _dio;

  Future<T> _call<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }

  @override
  Future<MySessions> mine() => _call(() async {
    final r = await _dio.get<Map<String, dynamic>>('/api/sessions/me');
    return MySessions.fromJson(r.data!);
  });

  @override
  Future<SessionInfo> create({required String name, required PauseMode mode}) =>
      _call(() async {
        final r = await _dio.post<Map<String, dynamic>>(
          '/api/sessions',
          data: {'name': name, 'pause_mode': mode.apiValue},
        );
        return SessionInfo.fromJson(r.data!);
      });

  @override
  Future<void> invite(String sessionId, List<String> userIds) => _call(
    () => _dio.post<void>(
      '/api/sessions/$sessionId/invite',
      data: {'user_ids': userIds},
    ),
  );

  @override
  Future<SessionInfo> join(String sessionId) => _call(() async {
    final r = await _dio.post<Map<String, dynamic>>(
      '/api/sessions/$sessionId/join',
    );
    return SessionInfo.fromJson(r.data!);
  });

  @override
  Future<void> leave(String sessionId) =>
      _call(() => _dio.post<void>('/api/sessions/$sessionId/leave'));

  @override
  Future<void> decline(String sessionId) =>
      _call(() => _dio.post<void>('/api/sessions/$sessionId/decline'));

  @override
  Future<SessionInfo> update(
    String sessionId, {
    String? name,
    PauseMode? mode,
  }) => _call(() async {
    final r = await _dio.patch<Map<String, dynamic>>(
      '/api/sessions/$sessionId',
      data: {'name': ?name, 'pause_mode': ?mode?.apiValue},
    );
    return SessionInfo.fromJson(r.data!);
  });

  @override
  Future<void> end(String sessionId) =>
      _call(() => _dio.delete<void>('/api/sessions/$sessionId'));

  @override
  Future<void> kick(String sessionId, String userId) => _call(
    () => _dio.delete<void>('/api/sessions/$sessionId/members/$userId'),
  );

  @override
  Future<SessionPlayback> act(String sessionId, Map<String, Object?> action) =>
      _call(() async {
        final r = await _dio.post<Map<String, dynamic>>(
          '/api/sessions/$sessionId/actions',
          data: action,
        );
        return SessionPlayback.fromJson(r.data!);
      });
}

final sessionRepositoryProvider = Provider<SessionRepository>(
  (ref) => HttpSessionRepository(ref.watch(apiDioProvider)),
);

// ── Tempo real ───────────────────────────────────────────────────────

/// Conexão em tempo real com a sessão. [closeCode] diz por que caiu
/// (4401: login vencido; 4403: não participa mais; nulo: rede).
abstract interface class SessionSocket {
  Stream<Map<String, dynamic>> get messages;
  int? get closeCode;
  void send(Map<String, dynamic> message);
  Future<void> close();
}

class WebSessionSocket implements SessionSocket {
  WebSessionSocket(Uri url) : _channel = WebSocketChannel.connect(url);

  final WebSocketChannel _channel;

  @override
  late final Stream<Map<String, dynamic>> messages = _channel.stream
      .map((raw) => jsonDecode(raw as String) as Map<String, dynamic>)
      .asBroadcastStream();

  @override
  int? get closeCode => _channel.closeCode;

  /// Envia depois de conectar (a ordem se mantém). Falha de conexão chega
  /// pelo fim de [messages].
  @override
  void send(Map<String, dynamic> message) {
    final data = jsonEncode(message);
    unawaited(
      _channel.ready.then((_) => _channel.sink.add(data), onError: (_) {}),
    );
  }

  @override
  Future<void> close() => _channel.sink.close();
}

/// Abre a conexão de uma sessão: `wss://servidor/api/sessions/{id}/ws`.
/// O token vai na primeira mensagem (fora da URL, que aparece em logs).
typedef SessionSocketFactory =
    SessionSocket Function({required String server, required String sessionId});

/// Endereço do WebSocket a partir do endereço do servidor.
Uri sessionSocketUrl(String server, String sessionId) {
  final base = Uri.parse(server);
  var path = base.path;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  return base.replace(
    scheme: base.scheme == 'https' ? 'wss' : 'ws',
    path: '$path/api/sessions/$sessionId/ws',
  );
}

final sessionSocketFactoryProvider = Provider<SessionSocketFactory>(
  (ref) =>
      ({required server, required sessionId}) =>
          WebSessionSocket(sessionSocketUrl(server, sessionId)),
);

// ── Para testes ──────────────────────────────────────────────────────

/// Repositório em memória: guarda as chamadas e devolve [current].
class FakeSessionRepository implements SessionRepository {
  FakeSessionRepository({this.current, this.invites = const []});

  static const me = Person(id: 'u-demo', username: 'demo', name: 'Demo');

  SessionInfo? current;
  List<SessionInvite> invites;
  final calls = <String>[];
  final actions = <Map<String, Object?>>[];

  static SessionInfo session({
    String id = 's1',
    Person owner = me,
    PauseMode mode = PauseMode.all,
    List<SessionMember> members = const [
      SessionMember(user: me, status: 'joined', online: true),
    ],
    SessionPlayback playback = const SessionPlayback(),
  }) => SessionInfo(
    id: id,
    name: '',
    owner: owner,
    pauseMode: mode,
    members: members,
    playback: playback,
  );

  @override
  Future<MySessions> mine() async {
    calls.add('mine');
    return MySessions(current: current, invites: invites);
  }

  @override
  Future<SessionInfo> create({
    required String name,
    required PauseMode mode,
  }) async {
    calls.add('create:${mode.apiValue}');
    return current = session(mode: mode);
  }

  @override
  Future<void> invite(String sessionId, List<String> userIds) async =>
      calls.add('invite:${userIds.join(',')}');

  @override
  Future<SessionInfo> join(String sessionId) async {
    calls.add('join:$sessionId');
    invites = [
      for (final i in invites)
        if (i.sessionId != sessionId) i,
    ];
    return current ??= session(id: sessionId);
  }

  @override
  Future<void> leave(String sessionId) async {
    calls.add('leave:$sessionId');
    current = null;
  }

  @override
  Future<void> decline(String sessionId) async {
    calls.add('decline:$sessionId');
    invites = [
      for (final i in invites)
        if (i.sessionId != sessionId) i,
    ];
  }

  @override
  Future<SessionInfo> update(
    String sessionId, {
    String? name,
    PauseMode? mode,
  }) async {
    calls.add('update:${mode?.apiValue}');
    return current = current!.copyWith(pauseMode: mode);
  }

  @override
  Future<void> end(String sessionId) async {
    calls.add('end:$sessionId');
    current = null;
  }

  @override
  Future<void> kick(String sessionId, String userId) async =>
      calls.add('kick:$userId');

  @override
  Future<SessionPlayback> act(
    String sessionId,
    Map<String, Object?> action,
  ) async {
    actions.add(action);
    return current?.playback ?? const SessionPlayback();
  }
}

/// Conexão falsa: o teste faz o papel do servidor com [receive] e confere
/// o que o app mandou em [sent].
class FakeSessionSocket implements SessionSocket {
  final _controller = StreamController<Map<String, dynamic>>.broadcast();
  final sent = <Map<String, dynamic>>[];

  @override
  int? closeCode;

  bool closed = false;

  @override
  Stream<Map<String, dynamic>> get messages => _controller.stream;

  /// Mensagem do "servidor".
  void receive(Map<String, dynamic> message) => _controller.add(message);

  /// Conexão caiu (com o código de fechamento).
  Future<void> drop([int? code]) {
    closeCode = code;
    return _controller.close();
  }

  List<Map<String, dynamic>> sentOfType(String type) => [
    for (final m in sent)
      if (m['type'] == type) m,
  ];

  @override
  void send(Map<String, dynamic> message) => sent.add(message);

  @override
  Future<void> close() async {
    closed = true;
    if (!_controller.isClosed) await _controller.close();
  }
}
