import 'dart:async';
import 'dart:math' as math;

import '../../../data/models/search_result.dart';
import '../output_engine.dart';
import 'cast_channel.dart';

/// Toca num Chromecast pelo receptor de mídia padrão do Google: o aparelho
/// busca a música no servidor pela URL (token curto) e este motor só manda
/// os comandos e acompanha a posição.
class CastEngine implements RemoteRenderer {
  CastEngine._(this.name, this._channel) {
    _sub = _channel.messages.listen(_onMessage);
    unawaited(_channel.closed.then((_) => _lostNow()));
  }

  /// Abre o receptor de mídia no aparelho e se conecta a ele.
  static Future<CastEngine> open(String name, CastChannel channel) async {
    final engine = CastEngine._(name, channel);
    try {
      await engine._launch();
    } on Object {
      channel.close();
      rethrow;
    }
    return engine;
  }

  @override
  final String name;

  @override
  String get kind => 'Chromecast';

  final CastChannel _channel;
  late final StreamSubscription<CastMessage> _sub;
  String? _transportId;
  String? _sessionId;
  int? _mediaSessionId;
  SearchResult? _track;

  // Última posição informada pelo aparelho e quando chegou: entre um
  // aviso e outro, a posição anda pelo relógio daqui.
  Duration _reported = Duration.zero;
  DateTime _reportedAt = DateTime.now();
  bool _playing = false;
  bool _finishedSent = false;
  Duration? _duration;
  Timer? _ticker;
  Timer? _volumeDebounce;

  final _position = StreamController<Duration>.broadcast();
  final _durationCtl = StreamController<Duration?>.broadcast();
  final _completed = StreamController<void>.broadcast();
  final _playingCtl = StreamController<bool>.broadcast();
  final _errors = StreamController<Object>.broadcast();
  final _lost = StreamController<void>.broadcast();

  Future<void> _launch() async {
    final status = await _channel.request(CastNs.receiver, {
      'type': 'LAUNCH',
      'appId': CastChannel.defaultMediaReceiver,
    });
    final apps =
        ((status['status'] as Map?)?['applications'] as List?) ?? const [];
    final app = apps.cast<Map<String, dynamic>>().firstWhere(
      (a) => a['appId'] == CastChannel.defaultMediaReceiver,
      orElse: () => throw StateError('O Chromecast não abriu o receptor'),
    );
    _transportId = app['transportId'] as String;
    _sessionId = app['sessionId'] as String?;
    _channel.send(CastNs.connection, {
      'type': 'CONNECT',
    }, destination: _transportId!);
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (_mediaSessionId != null) _position.add(position);
    });
  }

  void _media(String type, [Map<String, Object?> extra = const {}]) {
    final id = _mediaSessionId;
    final dest = _transportId;
    if (id == null || dest == null) return;
    _channel.send(CastNs.media, {
      'type': type,
      'mediaSessionId': id,
      'requestId': 0,
      ...extra,
    }, destination: dest);
  }

  void _onMessage(CastMessage m) {
    final json = m.json;
    switch (json['type']) {
      case 'MEDIA_STATUS':
        final list = (json['status'] as List?) ?? const [];
        if (list.isEmpty) return;
        _onStatus(list.first as Map<String, dynamic>);
      case 'LOAD_FAILED' || 'LOAD_CANCELLED' || 'INVALID_REQUEST':
        _errors.add(StateError('Chromecast: ${json['type']}'));
      case 'RECEIVER_STATUS':
        // Outro aparelho abriu outro app no Chromecast: a sessão acabou.
        final apps =
            ((json['status'] as Map?)?['applications'] as List?) ?? const [];
        final ours = apps.whereType<Map<String, dynamic>>().any(
          (a) => a['sessionId'] == _sessionId,
        );
        if (_sessionId != null && !ours) _lostNow();
      case 'CLOSE':
        if (m.source == _transportId) _lostNow();
    }
  }

  void _onStatus(Map<String, dynamic> s) {
    _mediaSessionId = s['mediaSessionId'] as int? ?? _mediaSessionId;
    final media = s['media'] as Map<String, dynamic>?;
    if (media?['duration'] case final num d) {
      _duration = Duration(milliseconds: (d * 1000).round());
      _durationCtl.add(_duration);
    }
    if (s['currentTime'] case final num t) {
      _reported = Duration(milliseconds: (t * 1000).round());
      _reportedAt = DateTime.now();
    }
    final state = s['playerState'] as String?;
    final playing = state == 'PLAYING' || state == 'BUFFERING';
    if (playing != _playing) {
      _playing = playing;
      _playingCtl.add(playing);
    }
    if (state == 'IDLE') {
      switch (s['idleReason']) {
        case 'FINISHED':
          if (!_finishedSent) {
            _finishedSent = true;
            _completed.add(null);
          }
        case 'ERROR':
          _errors.add(StateError('O Chromecast não conseguiu tocar'));
      }
    }
  }

  @override
  void describe(SearchResult track) => _track = track;

  @override
  Future<void> setUrl(Uri url) async {
    final dest = _transportId;
    if (dest == null) throw StateError('Chromecast sem receptor');
    final t = _track;
    _finishedSent = false;
    _reported = Duration.zero;
    _reportedAt = DateTime.now();
    final status = await _channel.request(CastNs.media, {
      'type': 'LOAD',
      'sessionId': _sessionId,
      'autoplay': false,
      'currentTime': 0,
      'media': {
        'contentId': url.toString(),
        'contentType': 'audio/mpeg',
        'streamType': 'BUFFERED',
        'metadata': {
          'metadataType': 3, // música
          'title': t?.title ?? '',
          'artist': t?.artist ?? '',
          'albumName': t?.album ?? '',
          if (t?.coverUrl case final cover?)
            'images': [
              {'url': cover},
            ],
        },
      },
    }, destination: dest);
    if (status['type'] != 'MEDIA_STATUS') {
      throw StateError('Chromecast recusou a música (${status['type']})');
    }
    final list = (status['status'] as List?) ?? const [];
    if (list.isNotEmpty) _onStatus(list.first as Map<String, dynamic>);
  }

  @override
  Future<void> setFile(String path) =>
      throw UnsupportedError('O Chromecast toca pelo servidor');

  @override
  void play() {
    _media('PLAY');
    _reportedAt = DateTime.now();
    if (!_playing) {
      _playing = true;
      _playingCtl.add(true);
    }
  }

  @override
  Future<void> pause() async {
    _reported = position;
    _reportedAt = DateTime.now();
    _media('PAUSE');
    if (_playing) {
      _playing = false;
      _playingCtl.add(false);
    }
  }

  @override
  Future<void> seek(Duration position) async {
    _reported = position;
    _reportedAt = DateTime.now();
    _media('SEEK', {'currentTime': position.inMilliseconds / 1000});
  }

  @override
  Future<void> stop() async => _media('STOP');

  /// Volume do Chromecast (o da barra; [volume] chega em amplitude, na curva
  /// cúbica). Espera a barra parar para não mandar um comando por passo.
  @override
  Future<void> setVolume(double volume) async {
    _volumeDebounce?.cancel();
    _volumeDebounce = Timer(const Duration(milliseconds: 250), () {
      final level = math.pow(volume.clamp(0, 1), 1 / 3).toDouble();
      _channel.send(CastNs.receiver, {
        'type': 'SET_VOLUME',
        'requestId': 0,
        'volume': {'level': level},
      });
    });
  }

  /// O servidor já normaliza: o Chromecast não precisa subir nada.
  @override
  Future<void> setBoost(double db) async {}

  @override
  double get maxBoostDb => 0;

  @override
  Duration get position {
    if (!_playing) return _reported;
    final now = _reported + DateTime.now().difference(_reportedAt);
    final d = _duration;
    return d != null && now > d ? d : now;
  }

  @override
  Stream<Duration> get positionStream => _position.stream;

  @override
  Stream<Duration?> get durationStream => _durationCtl.stream;

  @override
  Stream<void> get completedStream => _completed.stream;

  @override
  Stream<bool> get playingStream => _playingCtl.stream;

  @override
  Stream<Object> get errorStream => _errors.stream;

  @override
  Stream<void> get lostStream => _lost.stream;

  bool _lostSent = false;

  void _lostNow() {
    if (_lostSent || _disposed) return;
    _lostSent = true;
    _lost.add(null);
  }

  bool _disposed = false;

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _ticker?.cancel();
    _volumeDebounce?.cancel();
    await _sub.cancel();
    _channel.close();
    for (final c in [
      _position,
      _durationCtl,
      _completed,
      _playingCtl,
      _errors,
      _lost,
    ]) {
      await c.close();
    }
  }
}
