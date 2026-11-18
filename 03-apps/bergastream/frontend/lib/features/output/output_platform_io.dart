import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:multicast_dns/multicast_dns.dart';

import 'cast/cast_channel.dart';
import 'cast/cast_engine.dart';
import 'dlna/dlna.dart';
import 'output_devices.dart';
import 'output_engine.dart';

OutputPlatform createOutputPlatform() => IoOutputPlatform();

/// Android, Windows e Linux: Chromecast por mDNS (`_googlecast._tcp`) e
/// TVs por SSDP, ao mesmo tempo.
class IoOutputPlatform implements OutputPlatform {
  /// No Android o sistema descarta o multicast da rede sem esta trava.
  static const _multicast = MethodChannel('bergastream/multicast');

  static bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<List<OutputDevice>> discover() async {
    if (_android) {
      try {
        await _multicast.invokeMethod<void>('acquire');
      } on Object catch (e) {
        debugPrint('Trava de multicast: $e');
      }
    }
    try {
      final results = await Future.wait([
        _cast().catchError((Object e) {
          debugPrint('Busca de Chromecast: $e');
          return <OutputDevice>[];
        }),
        discoverDlna().then(
          (list) => [
            for (final d in list)
              OutputDevice(id: d.id, name: d.name, kind: 'DLNA', data: d),
          ],
          onError: (Object e) {
            debugPrint('Busca DLNA: $e');
            return <OutputDevice>[];
          },
        ),
      ]);
      // Chromecast com DLNA (algumas TVs têm os dois): fica o Chromecast.
      final cast = results[0];
      final castNames = {for (final c in cast) c.name};
      return [
        ...cast,
        for (final d in results[1])
          if (!castNames.contains(d.name)) d,
      ];
    } finally {
      if (_android) {
        try {
          await _multicast.invokeMethod<void>('release');
        } on Object {
          // sem a trava
        }
      }
    }
  }

  Future<List<OutputDevice>> _cast() async {
    // Windows não aceita reusePort no socket do multicast.
    final client = MDnsClient(
      rawDatagramSocketFactory:
          (
            host,
            int port, {
            bool reuseAddress = true,
            bool reusePort = true,
            int ttl = 1,
          }) => RawDatagramSocket.bind(
            host,
            port,
            reuseAddress: true,
            reusePort: !Platform.isWindows && reusePort,
            ttl: ttl,
          ),
    );
    await client.start();
    final found = <String, OutputDevice>{};
    try {
      const service = '_googlecast._tcp.local';
      await for (final ptr
          in client
              .lookup<PtrResourceRecord>(
                ResourceRecordQuery.serverPointer(service),
              )
              .timeout(
                const Duration(seconds: 3),
                onTimeout: (sink) => sink.close(),
              )) {
        await for (final srv
            in client
                .lookup<SrvResourceRecord>(
                  ResourceRecordQuery.service(ptr.domainName),
                )
                .timeout(
                  const Duration(seconds: 2),
                  onTimeout: (s) => s.close(),
                )) {
          var name = ptr.domainName.split('.').first;
          await for (final txt
              in client
                  .lookup<TxtResourceRecord>(
                    ResourceRecordQuery.text(ptr.domainName),
                  )
                  .timeout(
                    const Duration(seconds: 2),
                    onTimeout: (s) => s.close(),
                  )) {
            for (final entry in txt.text.split('\n')) {
              if (entry.startsWith('fn=')) name = entry.substring(3);
            }
          }
          String? ip;
          await for (final a
              in client
                  .lookup<IPAddressResourceRecord>(
                    ResourceRecordQuery.addressIPv4(srv.target),
                  )
                  .timeout(
                    const Duration(seconds: 2),
                    onTimeout: (s) => s.close(),
                  )) {
            ip = a.address.address;
            break;
          }
          if (ip == null) continue;
          found[ptr.domainName] = OutputDevice(
            id: ptr.domainName,
            name: name,
            kind: 'Chromecast',
            host: ip,
            port: srv.port,
          );
        }
      }
    } finally {
      client.stop();
    }
    return found.values.toList()..sort((a, b) => a.name.compareTo(b.name));
  }

  @override
  Future<RemoteRenderer> connect(OutputDevice device) async {
    switch (device.kind) {
      case 'Chromecast':
        final channel = await CastChannel.connect(
          device.host!,
          device.port ?? 8009,
        );
        return CastEngine.open(device.name, channel);
      case 'DLNA':
        return DlnaEngine(device.data! as DlnaDevice);
    }
    throw UnsupportedError('Aparelho desconhecido: ${device.kind}');
  }
}
