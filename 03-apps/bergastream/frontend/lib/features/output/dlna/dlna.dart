import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../../../data/models/search_result.dart';
import '../output_engine.dart';

/// TV ou caixa de som DLNA (UPnP "MediaRenderer"), achada na rede.
class DlnaDevice {
  const DlnaDevice({
    required this.name,
    required this.avTransport,
    this.renderingControl,
    required this.id,
  });

  final String name;
  final String id;

  /// URL de controle do AVTransport (tocar, pausar, avançar).
  final Uri avTransport;

  /// URL de controle do RenderingControl (volume); pode não existir.
  final Uri? renderingControl;
}

const _avt = 'urn:schemas-upnp-org:service:AVTransport:1';
const _rc = 'urn:schemas-upnp-org:service:RenderingControl:1';

/// Procura na rede (SSDP: multicast 239.255.255.250:1900) quem toca mídia.
Future<List<DlnaDevice>> discoverDlna({
  Duration wait = const Duration(seconds: 3),
  Future<String> Function(Uri)? fetch,
}) async {
  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  final locations = <String>{};
  final sub = socket.listen((event) {
    if (event != RawSocketEvent.read) return;
    final dg = socket.receive();
    if (dg == null) return;
    final location = ssdpLocation(utf8.decode(dg.data, allowMalformed: true));
    if (location != null) locations.add(location);
  });
  final search = utf8.encode(
    'M-SEARCH * HTTP/1.1\r\n'
    'HOST: 239.255.255.250:1900\r\n'
    'MAN: "ssdp:discover"\r\n'
    'MX: 2\r\n'
    'ST: $_avt\r\n\r\n',
  );
  final group = InternetAddress('239.255.255.250');
  for (var i = 0; i < 2; i++) {
    socket.send(search, group, 1900);
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  await Future<void>.delayed(wait);
  await sub.cancel();
  socket.close();
  final get = fetch ?? _get;
  final found = <String, DlnaDevice>{};
  await Future.wait([
    for (final loc in locations)
      () async {
        try {
          final uri = Uri.parse(loc);
          final device = parseDescription(await get(uri), uri);
          if (device != null) found[device.id] = device;
        } on Object {
          // aparelho que não respondeu a tempo
        }
      }(),
  ]);
  return found.values.toList()..sort((a, b) => a.name.compareTo(b.name));
}

Future<String> _get(Uri uri) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    final req = await client.getUrl(uri);
    final res = await req.close().timeout(const Duration(seconds: 4));
    return await res.transform(utf8.decoder).join();
  } finally {
    client.close(force: true);
  }
}

/// O "LOCATION:" de uma resposta SSDP.
String? ssdpLocation(String response) {
  for (final line in const LineSplitter().convert(response)) {
    final i = line.indexOf(':');
    if (i > 0 && line.substring(0, i).trim().toLowerCase() == 'location') {
      return line.substring(i + 1).trim();
    }
  }
  return null;
}

String? _tag(String xml, String tag) {
  final m = RegExp(
    '<(?:\\w+:)?$tag(?:\\s[^>]*)?>([\\s\\S]*?)</(?:\\w+:)?$tag>',
  ).firstMatch(xml);
  return m == null ? null : _unescape(m.group(1)!.trim());
}

String _unescape(String s) => s
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&');

String _escape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// Descrição do aparelho (XML do LOCATION): nome e as URLs de controle.
DlnaDevice? parseDescription(String xml, Uri location) {
  final name = _tag(xml, 'friendlyName') ?? location.host;
  final id = _tag(xml, 'UDN') ?? location.toString();
  Uri? controlOf(String type) {
    for (final m in RegExp(
      r'<(?:\w+:)?service>([\s\S]*?)</(?:\w+:)?service>',
    ).allMatches(xml)) {
      final block = m.group(1)!;
      if (_tag(block, 'serviceType') == type) {
        final url = _tag(block, 'controlURL');
        if (url != null) return location.resolve(url);
      }
    }
    return null;
  }

  final avt = controlOf(_avt);
  if (avt == null) return null;
  return DlnaDevice(
    name: name,
    id: id,
    avTransport: avt,
    renderingControl: controlOf(_rc),
  );
}

/// "00:03:25" ↔ Duration (formato do UPnP).
String upnpTime(Duration d) {
  final h = d.inHours.toString().padLeft(2, '0');
  final m = (d.inMinutes % 60).toString().padLeft(2, '0');
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '$h:$m:$s';
}

Duration? parseUpnpTime(String? text) {
  if (text == null || !text.contains(':')) return null;
  final parts = text.split(':');
  if (parts.length != 3) return null;
  final h = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  final s = double.tryParse(parts[2]);
  if (h == null || m == null || s == null) return null;
  return Duration(milliseconds: ((h * 3600 + m * 60 + s) * 1000).round());
}

/// Metadados DIDL-Lite: título, artista, capa e o tipo do áudio.
String didl(Uri url, SearchResult? t) =>
    '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
    'xmlns:dc="http://purl.org/dc/elements/1.1/" '
    'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
    '<item id="1" parentID="0" restricted="1">'
    '<dc:title>${_escape(t?.title ?? 'Bergastream')}</dc:title>'
    '<dc:creator>${_escape(t?.artist ?? '')}</dc:creator>'
    '<upnp:artist>${_escape(t?.artist ?? '')}</upnp:artist>'
    '<upnp:album>${_escape(t?.album ?? '')}</upnp:album>'
    '${t?.coverUrl == null ? '' : '<upnp:albumArtURI>${_escape(t!.coverUrl!)}</upnp:albumArtURI>'}'
    '<upnp:class>object.item.audioItem.musicTrack</upnp:class>'
    '<res protocolInfo="http-get:*:audio/mpeg:*">${_escape(url.toString())}</res>'
    '</item></DIDL-Lite>';

/// Chamada SOAP a um serviço UPnP.
typedef SoapCall =
    Future<String> Function(
      Uri control,
      String service,
      String action,
      Map<String, String> args,
    );

Future<String> soap(
  Uri control,
  String service,
  String action,
  Map<String, String> args,
) async {
  final body =
      '<?xml version="1.0" encoding="utf-8"?>'
      '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
      's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
      '<s:Body><u:$action xmlns:u="$service">'
      '${args.entries.map((e) => '<${e.key}>${_escape(e.value)}</${e.key}>').join()}'
      '</u:$action></s:Body></s:Envelope>';
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
  try {
    final req = await client.postUrl(control);
    req.headers
      ..set('Content-Type', 'text/xml; charset="utf-8"')
      ..set('SOAPACTION', '"$service#$action"');
    req.add(utf8.encode(body));
    final res = await req.close().timeout(const Duration(seconds: 6));
    final text = await res.transform(utf8.decoder).join();
    if (res.statusCode != 200) {
      throw HttpException('DLNA $action: ${res.statusCode}');
    }
    return text;
  } finally {
    client.close(force: true);
  }
}

/// Toca numa TV ou caixa DLNA. Os aparelhos não avisam nada: a posição e o
/// estado vêm consultando a cada segundo.
class DlnaEngine implements RemoteRenderer {
  DlnaEngine(this.device, {SoapCall? call, Duration? poll})
    : _call = call ?? soap {
    _timer = Timer.periodic(
      poll ?? const Duration(seconds: 1),
      (_) => unawaited(_refresh()),
    );
  }

  final DlnaDevice device;
  final SoapCall _call;
  late final Timer _timer;
  SearchResult? _track;
  Duration _reported = Duration.zero;
  DateTime _reportedAt = DateTime.now();
  Duration? _duration;
  bool _playing = false;
  bool _loaded = false;
  bool _wasPlaying = false;
  bool _finishedSent = false;
  int _failures = 0;
  bool _lostSent = false;
  Timer? _volumeDebounce;

  final _position = StreamController<Duration>.broadcast();
  final _durationCtl = StreamController<Duration?>.broadcast();
  final _completed = StreamController<void>.broadcast();
  final _playingCtl = StreamController<bool>.broadcast();
  final _errors = StreamController<Object>.broadcast();
  final _lost = StreamController<void>.broadcast();

  @override
  String get name => device.name;

  @override
  String get kind => 'DLNA';

  Future<String> _av(String action, [Map<String, String> args = const {}]) =>
      _call(device.avTransport, _avt, action, {'InstanceID': '0', ...args});

  Future<void> _refresh() async {
    if (!_loaded || _disposed) return;
    try {
      final pos = await _av('GetPositionInfo');
      final info = await _av('GetTransportInfo');
      _failures = 0;
      final rel = parseUpnpTime(_tag(pos, 'RelTime'));
      final dur = parseUpnpTime(_tag(pos, 'TrackDuration'));
      if (rel != null) {
        _reported = rel;
        _reportedAt = DateTime.now();
        _position.add(rel);
      }
      if (dur != null && dur > Duration.zero && dur != _duration) {
        _duration = dur;
        _durationCtl.add(dur);
      }
      final state = _tag(info, 'CurrentTransportState');
      final playing = state == 'PLAYING' || state == 'TRANSITIONING';
      if (playing != _playing) {
        _playing = playing;
        _playingCtl.add(playing);
      }
      if (playing) _wasPlaying = true;
      // Tocava e parou sozinho perto do fim: acabou a música.
      final d = _duration;
      if (state == 'STOPPED' &&
          _wasPlaying &&
          !_finishedSent &&
          (d == null || _reported > d - const Duration(seconds: 5))) {
        _finishedSent = true;
        _completed.add(null);
      }
    } on Object catch (e) {
      // Algumas falhas seguidas: a TV saiu da rede.
      if (++_failures >= 5) {
        if (!_lostSent) {
          _lostSent = true;
          _lost.add(null);
        }
      } else if (_failures == 1) {
        _errors.add(e);
      }
    }
  }

  @override
  void describe(SearchResult track) => _track = track;

  @override
  Future<void> setUrl(Uri url) async {
    _finishedSent = false;
    _wasPlaying = false;
    _reported = Duration.zero;
    _reportedAt = DateTime.now();
    _duration = null;
    try {
      await _av('Stop');
    } on Object {
      // nada tocando
    }
    await _av('SetAVTransportURI', {
      'CurrentURI': url.toString(),
      'CurrentURIMetaData': didl(url, _track),
    });
    _loaded = true;
  }

  @override
  Future<void> setFile(String path) =>
      throw UnsupportedError('A TV toca pelo servidor');

  @override
  void play() {
    _reportedAt = DateTime.now();
    if (!_playing) {
      _playing = true;
      _playingCtl.add(true);
    }
    unawaited(
      _av('Play', {'Speed': '1'}).catchError((Object e) {
        _errors.add(e);
        return '';
      }),
    );
  }

  @override
  Future<void> pause() async {
    _reported = position;
    if (_playing) {
      _playing = false;
      _playingCtl.add(false);
    }
    await _av('Pause');
  }

  @override
  Future<void> seek(Duration position) async {
    _reported = position;
    _reportedAt = DateTime.now();
    await _av('Seek', {'Unit': 'REL_TIME', 'Target': upnpTime(position)});
  }

  @override
  Future<void> stop() async {
    _loaded = false;
    await _av('Stop');
  }

  @override
  Future<void> setVolume(double volume) async {
    final control = device.renderingControl;
    if (control == null) return;
    _volumeDebounce?.cancel();
    _volumeDebounce = Timer(const Duration(milliseconds: 300), () {
      final level = (math.pow(volume.clamp(0, 1), 1 / 3) * 100).round();
      unawaited(
        _call(control, _rc, 'SetVolume', {
          'InstanceID': '0',
          'Channel': 'Master',
          'DesiredVolume': '$level',
        }).catchError((Object _) => ''),
      );
    });
  }

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

  bool _disposed = false;

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _timer.cancel();
    _volumeDebounce?.cancel();
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
