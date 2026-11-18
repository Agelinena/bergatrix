import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math' as math;

import 'package:web/web.dart' as web;

import '../../data/models/search_result.dart';
import 'output_devices.dart';
import 'output_engine.dart';

OutputPlatform createOutputPlatform() => WebOutputPlatform();

/// Navegador: Chromecast pelo SDK do Google (só no Chrome e derivados). O
/// navegador não deixa procurar aparelhos na rede: ao conectar, o Chrome
/// mostra a lista dele. DLNA não dá na web.
class WebOutputPlatform implements OutputPlatform {
  static const _sdk =
      'https://www.gstatic.com/cv/js/sender/v1/cast_sender.js?loadCastFramework=1';
  static Future<bool>? _loading;

  static JSObject get _window => globalContext;

  static Future<bool> _ensureSdk() => _loading ??= () async {
    final ready = Completer<bool>();
    _window.setProperty(
      '__onGCastApiAvailable'.toJS,
      ((JSBoolean available) {
        if (!ready.isCompleted) ready.complete(available.toDart);
      }).toJS,
    );
    final script = web.HTMLScriptElement()
      ..src = _sdk
      ..async = true;
    web.document.head!.appendChild(script);
    return ready.future.timeout(
      const Duration(seconds: 8),
      onTimeout: () => false,
    );
  }();

  @override
  Future<List<OutputDevice>> discover() async {
    if (!await _ensureSdk()) return const [];
    return const [
      OutputDevice(id: 'web-cast', name: 'Chromecast', kind: 'Chromecast'),
    ];
  }

  @override
  Future<RemoteRenderer> connect(OutputDevice device) async {
    if (!await _ensureSdk()) {
      throw UnsupportedError('Este navegador não tem Chromecast');
    }
    final framework = _window['cast'] as JSObject;
    final fw = framework['framework'] as JSObject;
    final contextClass = fw['CastContext'] as JSObject;
    final context = contextClass.callMethod<JSObject>('getInstance'.toJS);
    final chromeCast = (_window['chrome'] as JSObject)['cast'] as JSObject;
    final media = chromeCast['media'] as JSObject;
    final options = JSObject()
      ..['receiverApplicationId'] = media['DEFAULT_MEDIA_RECEIVER_APP_ID']
      ..['autoJoinPolicy'] =
          (chromeCast['AutoJoinPolicy'] as JSObject)['ORIGIN_SCOPED'];
    context.callMethod<JSAny?>('setOptions'.toJS, options);
    // Mostra a lista do Chrome; cancelar rejeita a promessa.
    await (context.callMethod<JSPromise<JSAny?>>('requestSession'.toJS)).toDart;
    final session = context.callMethod<JSObject?>('getCurrentSession'.toJS);
    if (session == null) throw StateError('Nenhum Chromecast escolhido');
    final castDevice = session.callMethod<JSObject>('getCastDevice'.toJS);
    final name = (castDevice['friendlyName'] as JSString?)?.toDart;
    return WebCastEngine(name ?? 'Chromecast', context, session, fw, media);
  }
}

/// Motor do Chromecast na web: carrega pela sessão do SDK e controla pelo
/// `RemotePlayerController`.
class WebCastEngine implements RemoteRenderer {
  WebCastEngine(
    this.name,
    this._context,
    this._session,
    this._fw,
    this._media,
  ) {
    _player = (_fw['RemotePlayer'] as JSFunction).callAsConstructor<JSObject>();
    _controller = (_fw['RemotePlayerController'] as JSFunction)
        .callAsConstructor<JSObject>(_player);
    final events = _fw['RemotePlayerEventType'] as JSObject;
    _listener = ((JSAny? _) => _onChange()).toJS;
    _controller.callMethod<JSAny?>(
      'addEventListener'.toJS,
      events['ANY_CHANGE'],
      _listener,
    );
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (_loaded) _position.add(position);
    });
  }

  @override
  final String name;

  @override
  String get kind => 'Chromecast';

  final JSObject _context;
  final JSObject _session;
  final JSObject _fw;
  final JSObject _media;
  late final JSObject _player;
  late final JSObject _controller;
  late final JSFunction _listener;
  late final Timer _ticker;
  SearchResult? _track;
  bool _loaded = false;
  bool _playing = false;
  bool _wasPlaying = false;
  bool _finishedSent = false;
  bool _lostSent = false;

  final _position = StreamController<Duration>.broadcast();
  final _durationCtl = StreamController<Duration?>.broadcast();
  final _completed = StreamController<void>.broadcast();
  final _playingCtl = StreamController<bool>.broadcast();
  final _errors = StreamController<Object>.broadcast();
  final _lost = StreamController<void>.broadcast();

  num _num(String key) => (_player[key] as JSNumber?)?.toDartDouble ?? 0;

  void _onChange() {
    final connected = (_player['isConnected'] as JSBoolean?)?.toDart ?? false;
    if (!connected) {
      if (!_lostSent) {
        _lostSent = true;
        _lost.add(null);
      }
      return;
    }
    final state = (_player['playerState'] as JSString?)?.toDart;
    final playing = state == 'PLAYING' || state == 'BUFFERING';
    if (playing != _playing) {
      _playing = playing;
      _playingCtl.add(playing);
    }
    if (playing) _wasPlaying = true;
    final duration = _num('duration');
    if (duration > 0) {
      _durationCtl.add(Duration(milliseconds: (duration * 1000).round()));
    }
    if (state == 'IDLE' && _wasPlaying && !_finishedSent && _loaded) {
      final ms = _session.callMethod<JSObject?>('getMediaSession'.toJS);
      final reason = (ms?['idleReason'] as JSString?)?.toDart;
      if (reason == null || reason == 'FINISHED') {
        _finishedSent = true;
        _completed.add(null);
      }
    }
  }

  @override
  void describe(SearchResult track) => _track = track;

  @override
  Future<void> setUrl(Uri url) async {
    _finishedSent = false;
    _wasPlaying = false;
    final info = (_media['MediaInfo'] as JSFunction)
        .callAsConstructor<JSObject>(url.toString().toJS, 'audio/mpeg'.toJS);
    final meta = (_media['MusicTrackMediaMetadata'] as JSFunction)
        .callAsConstructor<JSObject>();
    final t = _track;
    meta['title'] = (t?.title ?? '').toJS;
    meta['artist'] = (t?.artist ?? '').toJS;
    meta['albumName'] = (t?.album ?? '').toJS;
    if (t?.coverUrl case final cover?) {
      final chromeCast =
          (globalContext['chrome'] as JSObject)['cast'] as JSObject;
      final image = (chromeCast['Image'] as JSFunction)
          .callAsConstructor<JSObject>(cover.toJS);
      meta['images'] = [image].toJS;
    }
    info['metadata'] = meta;
    final request = (_media['LoadRequest'] as JSFunction)
        .callAsConstructor<JSObject>(info);
    request['autoplay'] = false.toJS;
    await _session
        .callMethod<JSPromise<JSAny?>>('loadMedia'.toJS, request)
        .toDart;
    _loaded = true;
  }

  @override
  Future<void> setFile(String path) =>
      throw UnsupportedError('O Chromecast toca pelo servidor');

  @override
  void play() {
    if (!_playing) _controller.callMethod<JSAny?>('playOrPause'.toJS);
  }

  @override
  Future<void> pause() async {
    if (_playing) _controller.callMethod<JSAny?>('playOrPause'.toJS);
  }

  @override
  Future<void> seek(Duration position) async {
    _player['currentTime'] = (position.inMilliseconds / 1000).toJS;
    _controller.callMethod<JSAny?>('seek'.toJS);
  }

  @override
  Future<void> stop() async {
    _loaded = false;
    _controller.callMethod<JSAny?>('stop'.toJS);
  }

  @override
  Future<void> setVolume(double volume) async {
    _player['volumeLevel'] = math
        .pow(volume.clamp(0, 1), 1 / 3)
        .toDouble()
        .toJS;
    _controller.callMethod<JSAny?>('setVolumeLevel'.toJS);
  }

  @override
  Future<void> setBoost(double db) async {}

  @override
  double get maxBoostDb => 0;

  @override
  Duration get position =>
      Duration(milliseconds: (_num('currentTime') * 1000).round());

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

  @override
  Future<void> dispose() async {
    _ticker.cancel();
    final events = _fw['RemotePlayerEventType'] as JSObject;
    _controller.callMethod<JSAny?>(
      'removeEventListener'.toJS,
      events['ANY_CHANGE'],
      _listener,
    );
    // Encerra a transmissão (para a música no aparelho).
    _context.callMethod<JSAny?>('endCurrentSession'.toJS, true.toJS);
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
