import 'package:bergastream/core/platform/app_platform.dart';
import 'package:bergastream/core/storage/key_value_store.dart';
import 'package:bergastream/data/local/database.dart';
import 'package:bergastream/data/models/playlist_models.dart';
import 'package:bergastream/data/repositories/playback_repository.dart';
import 'package:bergastream/data/repositories/session_repository.dart';
import 'package:bergastream/features/auth/session.dart';
import 'package:bergastream/features/player/audio_engine.dart';
import 'package:bergastream/features/player/player_controller.dart';
import 'package:bergastream/features/session/group_session.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../app_harness.dart';
import '../../fake_player.dart';

const marina = Person(id: 'u-marina', username: 'marina', name: 'Marina');

Map<String, dynamic> entry(String uid, String title) => {
  'uid': uid,
  'track': song(title).toJson(),
  'added_by': 'demo',
};

/// Reprodução no formato do servidor.
Map<String, dynamic> playback({
  List<String> titles = const ['A', 'B'],
  int index = 0,
  bool playing = true,
  int positionMs = 0,
  int anchorAt = start,
  int version = 1,
}) => {
  'queue': [for (final t in titles) entry('u$t', t)],
  'index': index,
  'playing': playing,
  'position_ms': positionMs,
  'anchor_at': anchorAt,
  'version': version,
};

Map<String, dynamic> sessionJson({
  String mode = 'all',
  Map<String, dynamic>? pb,
  int serverNow = start,
}) => {
  'id': 's1',
  'name': '',
  'owner': FakeSessionRepository.me.toJson(),
  'pause_mode': mode,
  'members': [
    {'user': FakeSessionRepository.me.toJson(), 'status': 'joined'},
    {'user': marina.toJson(), 'status': 'joined', 'online': true},
  ],
  'playback': pb ?? playback(),
  'server_now': serverNow,
};

/// Relógio dos testes (ms). O servidor está 0 ms à frente.
const start = 1000000;

void main() {
  late FakeAudioEngine engine;
  late FakeSessionRepository repo;
  late List<FakeSessionSocket> sockets;
  late int clock;
  late ProviderContainer container;
  late List<String> messages;

  PlayerController player() => container.read(playerProvider.notifier);
  PlayerState playerState() => container.read(playerProvider);
  GroupSessionController group() =>
      container.read(groupSessionProvider.notifier);
  GroupState groupState() => container.read(groupSessionProvider);
  FakeSessionSocket socket() => sockets.last;

  List<Map<String, dynamic>> actions() => [
    for (final m in socket().sentOfType('action')) Map.of(m)..remove('type'),
  ];

  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await pumpEventQueue();
    }
  }

  /// Entra na sessão e recebe o "hello".
  Future<void> joinWith(Map<String, dynamic> session) async {
    repo.current = SessionInfo.fromJson(session);
    await group().join('s1');
    socket().receive({'type': 'hello', 'session': session});
    await settle();
  }

  setUp(() {
    engine = FakeAudioEngine();
    repo = FakeSessionRepository();
    sockets = [];
    clock = start;
    container = ProviderContainer(
      overrides: [
        audioEngineProvider.overrideWithValue(engine),
        playbackRepositoryProvider.overrideWithValue(FakePlaybackRepository()),
        playerTimingsProvider.overrideWithValue(
          const PlayerTimings(
            pollInterval: Duration.zero,
            rapidChangeDelay: Duration.zero,
          ),
        ),
        playRecorderProvider.overrideWithValue((t, {playlistId}) {}),
        localDatabaseProvider.overrideWithValue(null),
        appPlatformProvider.overrideWithValue(const AppPlatform.app()),
        keyValueStoreProvider.overrideWithValue(MemoryKeyValueStore()),
        initialSessionProvider.overrideWithValue(loggedIn),
        sessionRepositoryProvider.overrideWithValue(repo),
        sessionSocketFactoryProvider.overrideWithValue(({
          required server,
          required sessionId,
        }) {
          final s = FakeSessionSocket();
          sockets.add(s);
          return s;
        }),
        groupTimingsProvider.overrideWithValue(
          const GroupTimings(
            invitePoll: null,
            syncCheck: null,
            keepAlive: null,
            reconnectDelays: [Duration.zero],
          ),
        ),
        groupClockProvider.overrideWithValue(() => clock),
      ],
    );
    addTearDown(container.dispose);
    container.read(playerProvider);
    messages = [];
    container.listen(playerProvider.select((s) => s.message), (_, m) {
      if (m != null) messages.add(m.text);
    });
    container.read(groupSessionProvider); // consulta /me (vazio)
  });

  test('endereço do WebSocket: wss, prefixo do servidor e sem token', () {
    expect(
      sessionSocketUrl('https://m.exemplo.com/api-access-bypass/', 's1'),
      Uri.parse('wss://m.exemplo.com/api-access-bypass/api/sessions/s1/ws'),
    );
    expect(
      sessionSocketUrl('http://192.168.0.2:8080', 's1').toString(),
      'ws://192.168.0.2:8080/api/sessions/s1/ws',
    );
  });

  test('posição esperada: âncora + tempo passado (pausada não anda)', () {
    final pb = SessionPlayback.fromJson(
      playback(positionMs: 10000, anchorAt: start),
    );
    expect(pb.positionAt(start + 5000), const Duration(seconds: 15));
    final paused = SessionPlayback.fromJson(
      playback(positionMs: 10000, anchorAt: start, playing: false),
    );
    expect(paused.positionAt(start + 5000), const Duration(seconds: 10));
  });

  test('entrar: autentica pela mensagem, carrega a faixa no ponto da sessão '
      'e toca', () async {
    await joinWith(
      sessionJson(pb: playback(positionMs: 30000, anchorAt: start - 5000)),
    );
    expect(socket().sent.first, {'type': 'auth', 'token': ''});
    expect(socket().sentOfType('ping'), hasLength(3));
    expect(groupState().connected, isTrue);
    expect(playerState().shared, isTrue);
    expect(playerState().current!.track.title, 'A');
    expect(playerState().upNext.map((i) => i.track.title), ['B']);
    expect(playerState().context, 'Sessão de Demo');
    expect(engine.log, containsAllInOrder(['setUrl', 'seek 35', 'play']));
    expect(playerState().status, PlaybackStatus.tocando);
  });

  test('controles viram ações da sessão (não mexem na fila local)', () async {
    await joinWith(sessionJson());
    await player().next();
    await player().addToQueue(song('C'));
    await player().seek(const Duration(seconds: 50));
    await player().previous(track: true);
    player().removeFromQueue(playerState().upNext.single.uid);
    expect(actions().map((a) => a['action']), [
      'next',
      'add',
      'seek',
      'previous', // primeira da fila: não há anterior para pular
      'remove',
    ]);
    expect(actions()[1]['track'], song('C').toJson());
    expect(actions()[2]['position_ms'], 50000);
    expect(actions()[4]['uid'], 'uB');
    // A fila só muda quando a sessão confirma.
    expect(playerState().current!.track.title, 'A');
  });

  test('tocar uma lista na sessão manda a lista para todos', () async {
    await joinWith(sessionJson());
    await player().playList(
      [song('X'), song('Y'), song('Z')],
      1,
      context: 'Playlist',
    );
    final action = actions().single;
    expect(action['action'], 'play_list');
    expect(action['index'], 1);
    expect((action['tracks'] as List).length, 3);
  });

  test('a sessão avança: carrega a próxima no ponto certo', () async {
    await joinWith(sessionJson());
    engine.log.clear();
    clock = start + 2000;
    socket().receive({
      'type': 'playback',
      'playback': playback(index: 1, anchorAt: start, version: 2),
      'server_now': start + 2000,
      'by': 'marina',
    });
    await settle();
    expect(playerState().current!.track.title, 'B');
    expect(engine.log, containsAllInOrder(['setUrl', 'seek 2', 'play']));
  });

  test('fim da faixa avisa a sessão com o uid (não avança sozinho)', () async {
    await joinWith(sessionJson());
    engine.complete();
    await settle();
    expect(actions().single, {'action': 'ended', 'uid': 'uA'});
    expect(playerState().current!.track.title, 'A');
  });

  test('"pausar para todos": pausa vira ação; pausa de outra pessoa '
      'pausa aqui e avisa', () async {
    await joinWith(sessionJson());
    await player().togglePlay();
    expect(actions().single, {'action': 'pause'});
    expect(engine.playing, isTrue); // espera a sessão confirmar

    socket().receive({
      'type': 'playback',
      'playback': playback(playing: false, positionMs: 4000, version: 2),
      'server_now': start,
      'by': 'marina',
    });
    await settle();
    expect(engine.playing, isFalse);
    expect(playerState().status, PlaybackStatus.pausado);
    expect(messages, ['Marina pausou']);
  });

  test(
    '"cada um pausa o seu": pausa só aqui e volta no ponto dos outros',
    () async {
      await joinWith(sessionJson(mode: 'individual'));
      await player().togglePlay();
      expect(actions(), isEmpty);
      expect(engine.playing, isFalse);
      expect(groupState().localPaused, isTrue);

      clock = start + 42000; // os outros seguiram ouvindo
      engine.log.clear();
      await player().togglePlay();
      expect(actions(), isEmpty);
      expect(engine.log, ['seek 42', 'play']);
      expect(playerState().status, PlaybackStatus.tocando);
    },
  );

  test('corrige atraso maior que 1,5 s; ignora pequenos', () async {
    await joinWith(sessionJson());
    clock = start + 20000;
    engine.currentPosition = const Duration(milliseconds: 19000);
    engine.log.clear();
    socket().receive({'type': 'session', 'session': sessionJson()});
    await settle();
    expect(engine.log, isEmpty);

    engine.currentPosition = const Duration(seconds: 10);
    socket().receive({'type': 'session', 'session': sessionJson()});
    await settle();
    expect(engine.log, ['seek 20']);
  });

  test('sessão encerrada: sai, para a música e avisa', () async {
    await joinWith(sessionJson());
    socket().receive({'type': 'ended'});
    await settle();
    expect(groupState().active, isFalse);
    expect(playerState().shared, isFalse);
    expect(engine.playing, isFalse);
    expect(messages, [GroupSessionController.ended]);
    expect(socket().closed, isTrue);
    // Fora da sessão os controles voltam a ser locais.
    await player().next();
    expect(sockets.single.sentOfType('action'), isEmpty);
  });

  test('conexão caiu: reconecta e se autentica de novo', () async {
    await joinWith(sessionJson());
    await socket().drop();
    await settle();
    expect(sockets, hasLength(2));
    expect(socket().sent.first['type'], 'auth');
    expect(groupState().active, isTrue);
  });

  test('4403 (não participa mais): sai da sessão', () async {
    await joinWith(sessionJson());
    await socket().drop(4403);
    await settle();
    expect(groupState().active, isFalse);
    expect(messages, [GroupSessionController.notMember]);
  });

  test('sem conexão em tempo real, a ação vai por HTTP', () async {
    repo.current = SessionInfo.fromJson(sessionJson());
    await group().join('s1');
    await settle();
    await player().next();
    await settle();
    expect(repo.actions.single, {'action': 'next'});
  });

  test('criar: a sessão começa com o que está tocando aqui', () async {
    await player().playList([song('A'), song('B')], 0, context: 'Busca');
    engine.currentPosition = const Duration(seconds: 12);
    await group().create(name: '', mode: PauseMode.all);
    await settle();
    expect(repo.calls, contains('create:all'));
    expect(repo.actions.map((a) => a['action']), ['play_list', 'seek']);
    expect((repo.actions.first['tracks'] as List).length, 2);
    expect(repo.actions[1]['position_ms'], 12000);
    expect(groupState().active, isTrue);
  });

  test('ao abrir o app numa sessão: reconecta sem tocar sozinho', () async {
    repo.current = SessionInfo.fromJson(sessionJson());
    await group().refresh(); // o app consulta /me ao abrir
    await settle();
    expect(groupState().active, isTrue);
    expect(groupState().localPaused, isTrue);
    expect(engine.playing, isFalse);
    expect(playerState().status, PlaybackStatus.pausado);

    await player().togglePlay();
    await settle();
    expect(engine.playing, isTrue);
  });

  test('convites pendentes chegam pela consulta', () async {
    repo.invites = [
      const SessionInvite(sessionId: 's9', name: '', owner: marina),
    ];
    await group().refresh();
    expect(groupState().invites.single.sessionId, 's9');
    await group().decline('s9');
    expect(groupState().invites, isEmpty);
    expect(repo.calls, contains('decline:s9'));
  });
}
