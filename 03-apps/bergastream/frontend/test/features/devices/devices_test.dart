import 'package:bergastream/core/platform/app_platform.dart';
import 'package:bergastream/core/storage/key_value_store.dart';
import 'package:bergastream/data/local/database.dart';
import 'package:bergastream/data/repositories/playback_repository.dart';
import 'package:bergastream/data/repositories/session_repository.dart';
import 'package:bergastream/features/auth/session.dart';
import 'package:bergastream/features/devices/device_controller.dart';
import 'package:bergastream/features/devices/device_identity.dart';
import 'package:bergastream/features/player/audio_engine.dart';
import 'package:bergastream/features/player/player_controller.dart';
import 'package:bergastream/features/session/group_session.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../app_harness.dart';
import '../../fake_player.dart';

const phone = {'id': 'dev-phone', 'name': 'Galaxy', 'platform': 'android'};
const me = {'id': 'dev-test', 'name': 'Teste', 'platform': 'web'};

Map<String, dynamic> devices({String? active}) => {
  'type': 'devices',
  'devices': [me, phone],
  'active': active,
};

/// Estado do celular tocando "Remota" (como o app manda).
Map<String, dynamic> remoteState({String status = 'tocando'}) => {
  'current': {'uid': 7, 'track': song('Remota').toJson()},
  'status': status,
  'position_ms': 30000,
  'duration_ms': 200000,
  'context': 'Rock',
  'shuffle': false,
  'repeat': 'desligado',
  'manual': [],
  'up_next': [
    {'uid': 8, 'track': song('Depois').toJson()},
  ],
};

void main() {
  late FakeAudioEngine engine;
  late List<FakeSessionSocket> sockets;
  late ProviderContainer container;

  PlayerController player() => container.read(playerProvider.notifier);
  PlayerState playerState() => container.read(playerProvider);
  DevicesState devicesState() => container.read(devicesProvider);
  FakeSessionSocket socket() => sockets.last;
  List<Map<String, dynamic>> sent(String type) => socket().sentOfType(type);

  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await pumpEventQueue();
    }
  }

  /// Conecta e recebe o "hello" (nada tocando, ou [active]).
  Future<void> connect({String? active}) async {
    container.read(devicesProvider);
    await settle();
    socket().receive({
      ...devices(active: active),
      'type': 'hello',
      'device_id': 'dev-test',
      'server_now': 0,
    });
    await settle();
  }

  setUp(() {
    engine = FakeAudioEngine();
    sockets = [];
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
        appPlatformProvider.overrideWithValue(const AppPlatform.web()),
        keyValueStoreProvider.overrideWithValue(MemoryKeyValueStore()),
        initialSessionProvider.overrideWithValue(loggedIn),
        sessionRepositoryProvider.overrideWithValue(FakeSessionRepository()),
        sessionSocketFactoryProvider.overrideWithValue(
          ({required server, required sessionId}) => FakeSessionSocket(),
        ),
        groupTimingsProvider.overrideWithValue(noGroupTimers),
        deviceIdentityProvider.overrideWith((ref) async => testDevice),
        deviceSocketFactoryProvider.overrideWithValue(({required server}) {
          final s = FakeSessionSocket();
          sockets.add(s);
          return s;
        }),
        deviceTimingsProvider.overrideWithValue(noDeviceTimers),
      ],
    );
    addTearDown(container.dispose);
    container.read(playerProvider);
  });

  test('endereço do WebSocket dos aparelhos', () {
    expect(
      deviceSocketUrl('https://m.exemplo.com/api-access-bypass/').toString(),
      'wss://m.exemplo.com/api-access-bypass/api/devices/ws',
    );
  });

  test('conecta se identificando (id, nome e plataforma)', () async {
    await connect();
    expect(sent('auth').single['device'], testDevice.toJson());
    expect(devicesState().connected, isTrue);
    expect(devicesState().devices.map((d) => d.name), ['Teste', 'Galaxy']);
  });

  test('tocar aqui com nenhum outro tocando: vira o ativo e conta aos '
      'outros', () async {
    await connect();
    await player().playList([song('A'), song('B')], 0, context: 'Busca');
    await settle();
    expect(sent('activate'), hasLength(1));
    expect(devicesState().activeHere, isTrue);
    final state = sent('state').last['state'] as Map<String, dynamic>;
    expect((state['current'] as Map)['track']['title'], 'A');
    expect(state['status'], 'tocando');
  });

  test('outro aparelho tocando: este para e vira controle remoto', () async {
    await connect();
    await player().playList([song('A')], 0, context: 'Busca');
    await settle();
    engine.log.clear();
    socket().receive(devices(active: 'dev-phone'));
    await settle();
    expect(engine.log, contains('pause'));
    expect(engine.playing, isFalse);
    expect(playerState().playingOn, 'Galaxy');

    socket().receive({
      'type': 'state',
      'state': remoteState(),
      'from': 'dev-phone',
    });
    await settle();
    expect(playerState().current!.track.title, 'Remota');
    expect(playerState().status, PlaybackStatus.tocando);
    expect(playerState().upNext.single.track.title, 'Depois');
    expect(playerState().context, 'Rock');

    // Os controles daqui comandam o celular.
    await player().next();
    await player().seek(const Duration(seconds: 90));
    await player().playList([song('X'), song('Y')], 1, context: 'Álbum');
    player().removeFromQueue(8);
    final commands = [for (final m in sent('command')) m['command'] as Map];
    expect(commands.map((c) => c['action']), [
      'next',
      'seek',
      'play_list',
      'remove',
    ]);
    expect(commands[1]['position_ms'], 90000);
    expect(commands[2]['index'], 1);
    expect(commands[3]['uid'], 8);
    expect(engine.playing, isFalse, reason: 'aqui continua calado');
  });

  test('o ativo sai: volta a ser o player daqui', () async {
    await connect(active: 'dev-phone');
    expect(playerState().playingOn, 'Galaxy');
    socket().receive(devices());
    await settle();
    expect(playerState().playingOn, isNull);
    expect(devicesState().canPlayHere, isTrue);
  });

  test('comando de outro aparelho é executado aqui (o ativo)', () async {
    await connect();
    await player().playList([song('A'), song('B')], 0, context: 'Busca');
    await settle();
    socket().receive({
      'type': 'command',
      'command': {'action': 'next'},
      'from': 'Galaxy',
    });
    await settle();
    expect(playerState().current!.track.title, 'B');
    final state = sent('state').last['state'] as Map<String, dynamic>;
    expect((state['current'] as Map)['track']['title'], 'B');
  });

  test('passar a vez: o ativo para e manda a fila e o ponto', () async {
    await connect();
    await player().playList([song('A'), song('B')], 0, context: 'Busca');
    await settle();
    engine.currentPosition = const Duration(seconds: 42);
    socket().receive({'type': 'handoff', 'to': 'dev-phone'});
    await settle();
    final state = sent('handoff_state').single['state'] as Map<String, dynamic>;
    expect(state['position_ms'], 42000);
    expect(state['playing'], isTrue);
    expect(state['queue'], isNotNull);
    expect(engine.playing, isFalse);
  });

  test('receber a vez: mesma fila, mesmo ponto, tocando', () async {
    // Fila de "outro aparelho" no formato da transferência.
    await player().playList([song('C'), song('D')], 1, context: 'Rock');
    await settle();
    final handoff = player().handoffState()
      ..['position_ms'] = 65000
      ..['playing'] = true;
    // Este aparelho tinha outra coisa e o celular era o ativo.
    await player().playList([song('Z')], 0, context: 'Busca');
    await connect(active: 'dev-phone');
    engine.log.clear();

    socket().receive({'type': 'play_here', 'state': handoff});
    await settle();
    expect(devicesState().activeHere, isTrue);
    expect(playerState().playingOn, isNull);
    expect(playerState().current!.track.title, 'D');
    expect(playerState().context, 'Rock');
    expect(engine.log, containsAllInOrder(['setUrl', 'seek 65', 'play']));
  });

  test('"Tocar em" outro aparelho leva a fila daqui', () async {
    await connect();
    await player().playList([song('A'), song('B')], 0, context: 'Busca');
    await settle();
    container.read(devicesProvider.notifier).transfer('dev-phone');
    final transfer = sent('transfer').single;
    expect(transfer['to'], 'dev-phone');
    expect((transfer['state'] as Map)['queue'], isNotNull);
    expect(engine.playing, isFalse);
  });

  test('"Tocar em" este aparelho com outro tocando pede a vez', () async {
    await connect(active: 'dev-phone');
    container.read(devicesProvider.notifier).transfer('dev-test');
    expect(sent('transfer').single, {'type': 'transfer', 'to': 'dev-test'});
  });

  test('na sessão "ouvir junto", só o aparelho ativo sai som', () async {
    await connect();
    final repo =
        container.read(sessionRepositoryProvider) as FakeSessionRepository;
    repo.current = FakeSessionRepository.session(
      playback: SessionPlayback.fromJson({
        'queue': [
          {'uid': 'uA', 'track': song('A').toJson()},
        ],
        'index': 0,
        'playing': true,
        'position_ms': 0,
        'anchor_at': DateTime.now().millisecondsSinceEpoch,
        'version': 1,
      }),
    );
    // Entrar por aqui faz deste o aparelho que toca.
    await container.read(groupSessionProvider.notifier).join('s1');
    await settle();
    expect(sent('activate'), hasLength(1));
    expect(engine.playing, isTrue);

    // O celular assume: aqui segue a sessão calado, mostrando onde toca.
    socket().receive(devices(active: 'dev-phone'));
    await settle();
    expect(engine.playing, isFalse);
    expect(playerState().shared, isTrue);
    expect(playerState().playingOn, 'Galaxy');
    expect(playerState().current!.track.title, 'A');
  });
}
