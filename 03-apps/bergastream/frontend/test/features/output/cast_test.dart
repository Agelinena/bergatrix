import 'dart:async';
import 'dart:convert';

import 'package:bergastream/data/models/search_result.dart';
import 'package:bergastream/features/output/cast/cast_channel.dart';
import 'package:bergastream/features/output/cast/cast_engine.dart';
import 'package:flutter_test/flutter_test.dart';

/// Chromecast simulado: lê o que o app manda e responde como o aparelho.
class FakeChromecast {
  FakeChromecast() {
    channel = CastChannel(_toApp.stream, _fromApp, () => closed = true);
  }

  final _toApp = StreamController<List<int>>();
  final _reader = CastFrameReader();
  final sent = <CastMessage>[];
  late final CastChannel channel;
  bool closed = false;
  bool answerLaunch = true;

  List<Map<String, dynamic>> ofType(String type) => [
    for (final m in sent)
      if (m.json['type'] == type) m.json,
  ];

  void _fromApp(List<int> bytes) {
    for (final m in _reader.add(bytes)) {
      sent.add(m);
      final json = m.json;
      if (json['type'] == 'LAUNCH' && answerLaunch) {
        reply(m, {
          'type': 'RECEIVER_STATUS',
          'requestId': json['requestId'],
          'status': {
            'applications': [
              {
                'appId': CastChannel.defaultMediaReceiver,
                'transportId': 'web-1',
                'sessionId': 'sess-1',
              },
            ],
          },
        });
      }
      if (json['type'] == 'LOAD') {
        reply(m, {
          'type': 'MEDIA_STATUS',
          'requestId': json['requestId'],
          'status': [
            {
              'mediaSessionId': 7,
              'playerState': 'PAUSED',
              'currentTime': 0,
              'media': {'duration': 200.0},
            },
          ],
        });
      }
    }
  }

  void reply(CastMessage to, Map<String, Object?> payload) =>
      push(payload, source: to.destination, namespace: to.namespace);

  void push(
    Map<String, Object?> payload, {
    String source = 'web-1',
    String namespace = CastNs.media,
  }) {
    final bytes = CastMessage(
      source: source,
      destination: CastChannel.sender,
      namespace: namespace,
      payload: jsonEncode(payload),
    ).encode();
    // Chega aos pedaços, como pela rede.
    _toApp
      ..add(bytes.sublist(0, 3))
      ..add(bytes.sublist(3));
  }
}

const song = SearchResult(
  provider: 'deezer',
  externalId: '1',
  title: 'Lonely Day',
  artist: 'System Of A Down',
  album: 'Hypnotize',
  coverUrl: 'https://img/capa.jpg',
);

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 10));

void main() {
  test('mensagem do Cast: codifica e lê de volta (protobuf + tamanho)', () {
    const m = CastMessage(
      source: 'a',
      destination: 'b',
      namespace: CastNs.media,
      payload: '{"type":"PLAY","texto":"ação"}',
    );
    final reader = CastFrameReader();
    final bytes = m.encode();
    expect(reader.add(bytes.sublist(0, 5)), isEmpty, reason: 'incompleta');
    final back = reader.add(bytes.sublist(5)).single;
    expect(
      (back.source, back.destination, back.namespace, back.json['texto']),
      ('a', 'b', CastNs.media, 'ação'),
    );
  });

  test(
    'abre o receptor, carrega com título e capa, toca e avisa o fim',
    () async {
      final tv = FakeChromecast();
      final engine = await CastEngine.open('Sala', tv.channel);
      expect(tv.ofType('CONNECT'), hasLength(2), reason: 'receiver-0 e o app');
      expect(tv.ofType('LAUNCH').single['appId'], 'CC1AD845');

      engine.describe(song);
      await engine.setUrl(Uri.parse('https://s/stream?t=x&quality=high'));
      final load = tv.ofType('LOAD').single;
      expect(load['media']['contentId'], 'https://s/stream?t=x&quality=high');
      expect(load['media']['metadata']['title'], 'Lonely Day');
      expect(
        load['media']['metadata']['images'][0]['url'],
        'https://img/capa.jpg',
      );

      final playing = <bool>[];
      engine.playingStream.listen(playing.add);
      engine.play();
      await engine.seek(const Duration(seconds: 30));
      expect(tv.ofType('PLAY').single['mediaSessionId'], 7);
      expect(tv.ofType('SEEK').single['currentTime'], 30);
      expect(playing, [true]);

      var finished = 0;
      engine.completedStream.listen((_) => finished++);
      tv.push({
        'type': 'MEDIA_STATUS',
        'status': [
          {
            'mediaSessionId': 7,
            'playerState': 'IDLE',
            'idleReason': 'FINISHED',
          },
        ],
      });
      tv.push({
        'type': 'MEDIA_STATUS',
        'status': [
          {
            'mediaSessionId': 7,
            'playerState': 'IDLE',
            'idleReason': 'FINISHED',
          },
        ],
      });
      await settle();
      expect(finished, 1, reason: 'um aviso por música');
      await engine.dispose();
      expect(tv.closed, isTrue);
    },
  );

  test('responde aos batimentos (PING → PONG)', () async {
    final tv = FakeChromecast();
    tv.push(
      {'type': 'PING'},
      source: 'receiver-0',
      namespace: CastNs.heartbeat,
    );
    await settle();
    expect(tv.ofType('PONG'), hasLength(1));
    tv.channel.close();
  });

  test('outro aparelho assumiu o Chromecast: avisa que caiu', () async {
    final tv = FakeChromecast();
    final engine = await CastEngine.open('Sala', tv.channel);
    var lost = 0;
    engine.lostStream.listen((_) => lost++);
    tv.push(
      {
        'type': 'RECEIVER_STATUS',
        'status': {
          'applications': [
            {'appId': 'YOUTUBE', 'sessionId': 'outro'},
          ],
        },
      },
      source: 'receiver-0',
      namespace: CastNs.receiver,
    );
    await settle();
    expect(lost, 1);
    await engine.dispose();
  });

  test('volume da barra vira o volume do Chromecast (sem a curva)', () async {
    final tv = FakeChromecast();
    final engine = await CastEngine.open('Sala', tv.channel);
    await engine.setVolume(0.125); // amplitude de 50% na curva cúbica
    await engine.setVolume(0.216); // 60%
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final volumes = tv.ofType('SET_VOLUME');
    expect(volumes, hasLength(1), reason: 'espera a barra parar');
    expect(volumes.single['volume']['level'], closeTo(0.6, 0.001));
    await engine.dispose();
  });
}
