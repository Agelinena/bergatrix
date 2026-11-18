import 'package:bergastream/data/models/search_result.dart';
import 'package:bergastream/features/output/dlna/dlna.dart';
import 'package:flutter_test/flutter_test.dart';

const description = '''<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <device>
    <friendlyName>[TV] Samsung Sala</friendlyName>
    <UDN>uuid:tv-1</UDN>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
        <controlURL>/upnp/control/RenderingControl1</controlURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
        <controlURL>/upnp/control/AVTransport1</controlURL>
      </service>
    </serviceList>
  </device>
</root>''';

/// TV simulada: guarda as chamadas e responde posição e estado.
class FakeTv {
  final calls = <(String, Map<String, String>)>[];
  String state = 'STOPPED';
  String rel = '00:00:00';
  String duration = '00:03:20';
  bool down = false;

  Future<String> call(
    Uri control,
    String service,
    String action,
    Map<String, String> args,
  ) async {
    if (down) throw Exception('sem resposta');
    calls.add((action, args));
    return switch (action) {
      'GetPositionInfo' =>
        '<RelTime>$rel</RelTime><TrackDuration>$duration</TrackDuration>',
      'GetTransportInfo' =>
        '<CurrentTransportState>$state</CurrentTransportState>',
      _ => '<ok/>',
    };
  }

  List<String> get actions => [for (final c in calls) c.$1];
}

const song = SearchResult(
  provider: 'deezer',
  externalId: '1',
  title: 'Rock & Roll',
  artist: 'Banda',
);

Future<void> wait() => Future<void>.delayed(const Duration(milliseconds: 60));

void main() {
  test('descrição da TV: nome e endereços de controle', () {
    final d = parseDescription(
      description,
      Uri.parse('http://192.0.2.10:9197/dmr'),
    )!;
    expect(d.name, '[TV] Samsung Sala');
    expect(d.id, 'uuid:tv-1');
    expect(
      d.avTransport.toString(),
      'http://192.0.2.10:9197/upnp/control/AVTransport1',
    );
    expect(d.renderingControl!.path, '/upnp/control/RenderingControl1');
    expect(
      ssdpLocation(
        'HTTP/1.1 200 OK\r\nLocation: http://192.0.2.10:9197/dmr\r\n',
      ),
      'http://192.0.2.10:9197/dmr',
    );
    expect(upnpTime(const Duration(minutes: 3, seconds: 5)), '00:03:05');
    expect(
      parseUpnpTime('00:01:02.500'),
      const Duration(seconds: 62, milliseconds: 500),
    );
  });

  test('carrega com título (escapado), toca, avança e avisa o fim', () async {
    final tv = FakeTv();
    final engine = DlnaEngine(
      parseDescription(description, Uri.parse('http://192.0.2.10:9197/dmr'))!,
      call: tv.call,
      poll: const Duration(milliseconds: 20),
    );
    engine.describe(song);
    await engine.setUrl(Uri.parse('https://s/stream?t=x&quality=high'));
    final load = tv.calls.firstWhere((c) => c.$1 == 'SetAVTransportURI').$2;
    expect(load['CurrentURI'], 'https://s/stream?t=x&quality=high');
    expect(
      load['CurrentURIMetaData'],
      contains('<dc:title>Rock &amp; Roll</dc:title>'),
    );
    expect(load['CurrentURIMetaData'], contains('audio/mpeg'));

    engine.play();
    await engine.seek(const Duration(seconds: 70));
    expect(tv.actions, containsAllInOrder(['Play', 'Seek']));
    expect(tv.calls.lastWhere((c) => c.$1 == 'Seek').$2['Target'], '00:01:10');

    var finished = 0;
    engine.completedStream.listen((_) => finished++);
    tv
      ..state = 'PLAYING'
      ..rel = '00:03:18';
    await wait();
    tv.state = 'STOPPED';
    await wait();
    expect(finished, 1);
    expect(engine.position, const Duration(minutes: 3, seconds: 18));
    await engine.dispose();
  });

  test('TV some da rede: avisa que caiu', () async {
    final tv = FakeTv();
    final engine = DlnaEngine(
      parseDescription(description, Uri.parse('http://192.0.2.10:9197/dmr'))!,
      call: tv.call,
      poll: const Duration(milliseconds: 10),
    );
    await engine.setUrl(Uri.parse('https://s/x'));
    var lost = 0;
    engine.lostStream.listen((_) => lost++);
    tv.down = true;
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(lost, greaterThanOrEqualTo(1));
    await engine.dispose();
  });
}
