/// Native Cast v2 implementation for Android, Linux, Windows, macOS.
///
/// Discovery: mDNS query for _googlecast._tcp.local
/// Transport: TLS socket on port 8009 (Chromecast default)
/// Protocol:  4-byte big-endian length + CastMessage protobuf (manually encoded)
/// Receiver:  Default Media Receiver (CC1AD845) — plays audio from URL natively
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:multicast_dns/multicast_dns.dart';
import 'cast_service.dart';
import 'cast_types.dart';

class CastServiceImpl implements CastService {
  SecureSocket? _socket;
  StreamSubscription<List<int>>? _socketSub;
  Timer? _heartbeatTimer;

  /// Transport/session identifiers from RECEIVER_STATUS response.
  String? _sessionId;
  String? _transportId;

  /// Ring buffer for incoming TCP data (frames may be split across packets).
  final _buffer = <int>[];

  final _eventController = StreamController<CastServiceEvent>.broadcast();

  int _requestId = 1;

  // ── Cast protocol constants ──────────────────────────────────────────────
  static const _sourceId = 'sender-bergastream-0';
  static const _receiverDest = 'receiver-0';
  static const _nsConnection = 'urn:x-cast:com.google.cast.tp.connection';
  static const _nsHeartbeat = 'urn:x-cast:com.google.cast.tp.heartbeat';
  static const _nsReceiver = 'urn:x-cast:com.google.cast.receiver';
  static const _nsMedia = 'urn:x-cast:com.google.cast.media';
  static const _defaultMediaReceiverId = 'CC1AD845';

  @override
  Stream<CastServiceEvent> get events => _eventController.stream;

  // ── Discovery ─────────────────────────────────────────────────────────────

  @override
  Future<List<CastDevice>> discoverDevices({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final devices = <CastDevice>[];
    final seen = <String>{};
    final client = MDnsClient();

    try {
      await client.start();

      final sub = client
          .lookup<PtrResourceRecord>(
            ResourceRecordQuery.serverPointer('_googlecast._tcp.local'),
          )
          .listen(
            (ptr) async {
              if (seen.contains(ptr.domainName)) return;
              seen.add(ptr.domainName);

              try {
                final srv = await client
                    .lookup<SrvResourceRecord>(
                      ResourceRecordQuery.service(ptr.domainName),
                    )
                    .first
                    .timeout(const Duration(seconds: 2));

                final ip = await client
                    .lookup<IPAddressResourceRecord>(
                      ResourceRecordQuery.addressIPv4(srv.target),
                    )
                    .first
                    .timeout(const Duration(seconds: 2));

                // Friendly name: strip mDNS suffix (e.g. "My Chromecast._googlecast._tcp.local")
                final rawName = ptr.domainName.split('._googlecast').first;
                devices.add(CastDevice(
                  name: rawName,
                  host: ip.address.address,
                  port: srv.port,
                ));
              } catch (_) {
                // Skip unresolvable records
              }
            },
            onError: (_) {},
          );

      // Discover for the requested timeout, then stop.
      await Future.delayed(timeout);
      await sub.cancel();
    } catch (e) {
      debugPrint('[Cast] discovery error: $e');
    } finally {
      client.stop();
    }

    return devices;
  }

  // ── Connection ────────────────────────────────────────────────────────────

  @override
  Future<void> connect(CastDevice device) async {
    await _disconnect();

    try {
      _socket = await SecureSocket.connect(
        device.host,
        device.port,
        // Chromecast uses a self-signed certificate — skip verification.
        onBadCertificate: (_) => true,
        timeout: const Duration(seconds: 10),
      );
    } catch (e) {
      _eventController.add(CastEventError('Não foi possível conectar: $e'));
      return;
    }

    _buffer.clear();
    _socketSub = _socket!.listen(
      _onData,
      onError: _onSocketError,
      onDone: _onSocketDone,
      cancelOnError: false,
    );

    // Step 1 — virtual connection to receiver transport layer
    _send(_nsConnection, _receiverDest, '{"type":"CONNECT","userAgent":"BergaStream/1.0"}');

    // Step 2 — launch the Default Media Receiver app
    _send(
      _nsReceiver,
      _receiverDest,
      jsonEncode({
        'type': 'LAUNCH',
        'appId': _defaultMediaReceiverId,
        'requestId': _requestId++,
      }),
    );

    _eventController.add(const CastEventConnecting());

    // Keep-alive heartbeat every 5 s
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _send(_nsHeartbeat, _receiverDest, '{"type":"PING"}');
    });
  }

  // ── Media control ─────────────────────────────────────────────────────────

  @override
  Future<void> loadMedia(
    String url,
    String title,
    String artist,
    String? coverUrl,
  ) async {
    final dest = _transportId;
    if (dest == null) {
      _eventController.add(const CastEventError('Nenhuma sessão Cast ativa.'));
      return;
    }

    final payload = jsonEncode({
      'type': 'LOAD',
      'requestId': _requestId++,
      'media': {
        'contentId': url,
        'streamType': 'BUFFERED',
        'contentType': 'audio/mpeg',
        'metadata': {
          'metadataType': 3, // MusicTrackMediaMetadata
          'title': title,
          'artist': artist,
          if (coverUrl != null)
            'images': [
              {'url': coverUrl}
            ],
        },
      },
      'autoplay': true,
      'currentTime': 0,
    });

    _send(_nsMedia, dest, payload);
  }

  @override
  Future<void> pause() async {
    final dest = _transportId;
    if (dest == null) return;
    _send(_nsMedia, dest, '{"type":"PAUSE","requestId":${_requestId++},"mediaSessionId":1}');
  }

  @override
  Future<void> resume() async {
    final dest = _transportId;
    if (dest == null) return;
    _send(_nsMedia, dest, '{"type":"PLAY","requestId":${_requestId++},"mediaSessionId":1}');
  }

  @override
  Future<void> stop() async {
    final dest = _transportId;
    if (dest != null) {
      _send(_nsMedia, dest, '{"type":"STOP","requestId":${_requestId++},"mediaSessionId":1}');
      await Future.delayed(const Duration(milliseconds: 200));
    }
    await _disconnect();
  }

  @override
  void dispose() {
    _disconnect();
    _eventController.close();
  }

  // ── Internal helpers ──────────────────────────────────────────────────────

  Future<void> _disconnect() async {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    await _socketSub?.cancel();
    _socketSub = null;
    try {
      await _socket?.close();
    } catch (_) {}
    _socket = null;
    _sessionId = null;
    _transportId = null;
    _buffer.clear();
    if (!_eventController.isClosed) {
      _eventController.add(const CastEventDisconnected());
    }
  }

  void _send(String namespace, String destination, String payload) {
    final s = _socket;
    if (s == null) return;
    try {
      final msg = _encodeCastMessage(
        sourceId: _sourceId,
        destinationId: destination,
        namespace: namespace,
        payload: payload,
      );
      // 4-byte big-endian length prefix
      final lenBytes = ByteData(4)..setUint32(0, msg.length, Endian.big);
      s.add(lenBytes.buffer.asUint8List());
      s.add(msg);
    } catch (e) {
      debugPrint('[Cast] send error: $e');
    }
  }

  void _onData(List<int> data) {
    _buffer.addAll(data);
    // Parse complete frames: [4-byte len][proto bytes...]
    while (_buffer.length >= 4) {
      final len = ByteData.sublistView(Uint8List.fromList(_buffer.sublist(0, 4)))
          .getUint32(0, Endian.big);
      if (_buffer.length < 4 + len) break;

      final msgBytes = Uint8List.fromList(_buffer.sublist(4, 4 + len));
      _buffer.removeRange(0, 4 + len);
      _processMessage(msgBytes);
    }
  }

  void _onSocketError(Object error) {
    debugPrint('[Cast] socket error: $error');
    if (!_eventController.isClosed) {
      _eventController.add(CastEventError(error.toString()));
    }
  }

  void _onSocketDone() {
    debugPrint('[Cast] socket closed by remote');
    _disconnect();
  }

  void _processMessage(Uint8List bytes) {
    try {
      final msg = _decodeCastMessage(bytes);
      final namespace = msg['namespace'] as String? ?? '';
      final payloadStr = msg['payload'] as String? ?? '';
      if (payloadStr.isEmpty) return;

      final payload = jsonDecode(payloadStr) as Map<String, dynamic>;
      final type = payload['type'] as String? ?? '';

      // Respond to heartbeat PINGs
      if (namespace == _nsHeartbeat && type == 'PING') {
        _send(_nsHeartbeat, _receiverDest, '{"type":"PONG"}');
        return;
      }

      // When the app is launched we receive RECEIVER_STATUS with session info
      if (namespace == _nsReceiver && type == 'RECEIVER_STATUS') {
        final status = payload['status'] as Map<String, dynamic>?;
        final apps = status?['applications'] as List<dynamic>?;
        if (apps != null && apps.isNotEmpty) {
          final app = apps.first as Map<String, dynamic>;
          final newTransport = app['transportId'] as String?;
          final newSession = app['sessionId'] as String?;

          if (newTransport != null && newTransport != _transportId) {
            _transportId = newTransport;
            _sessionId = newSession;

            // Connect virtual channel to the app session
            _send(_nsConnection, _transportId!, '{"type":"CONNECT"}');

            if (!_eventController.isClosed) {
              _eventController.add(const CastEventConnected());
            }
          }
        }
        return;
      }

      // Forward media status events to listeners
      if (namespace == _nsMedia && !_eventController.isClosed) {
        _eventController.add(CastEventMediaStatus(payload));
      }
    } catch (e) {
      debugPrint('[Cast] processMessage error: $e');
    }
  }

  // ── Minimal protobuf encoder for CastMessage ──────────────────────────────
  //
  // CastMessage fields:
  //   1 (varint)  protocol_version = 0 (CASTV2_1_0)
  //   2 (string)  source_id
  //   3 (string)  destination_id
  //   4 (string)  namespace
  //   5 (varint)  payload_type = 0 (STRING)
  //   7 (string)  payload_utf8

  static Uint8List _encodeCastMessage({
    required String sourceId,
    required String destinationId,
    required String namespace,
    required String payload,
  }) {
    final out = BytesBuilder();

    // Field 1 — protocol_version = 0
    out.addByte(0x08); // tag (1 << 3) | 0
    out.addByte(0x00);

    // Field 2 — source_id
    _writeStringField(out, 0x12, sourceId);

    // Field 3 — destination_id
    _writeStringField(out, 0x1A, destinationId);

    // Field 4 — namespace
    _writeStringField(out, 0x22, namespace);

    // Field 5 — payload_type = 0 (STRING)
    out.addByte(0x28); // tag (5 << 3) | 0
    out.addByte(0x00);

    // Field 7 — payload_utf8
    _writeStringField(out, 0x3A, payload);

    return out.toBytes();
  }

  static void _writeStringField(BytesBuilder out, int tag, String value) {
    final bytes = utf8.encode(value);
    out.addByte(tag);
    _writeVarint(out, bytes.length);
    out.add(bytes);
  }

  static void _writeVarint(BytesBuilder out, int value) {
    while (value >= 0x80) {
      out.addByte((value & 0x7F) | 0x80);
      value >>= 7;
    }
    out.addByte(value);
  }

  // ── Minimal protobuf decoder for CastMessage ──────────────────────────────

  static Map<String, dynamic> _decodeCastMessage(Uint8List bytes) {
    final result = <String, dynamic>{};
    int pos = 0;

    while (pos < bytes.length) {
      // Read varint tag
      int tag = 0;
      int shift = 0;
      while (pos < bytes.length) {
        final b = bytes[pos++];
        tag |= (b & 0x7F) << shift;
        if ((b & 0x80) == 0) break;
        shift += 7;
      }

      final fieldNum = tag >> 3;
      final wireType = tag & 0x07;

      if (wireType == 0) {
        // Varint
        int value = 0;
        shift = 0;
        while (pos < bytes.length) {
          final b = bytes[pos++];
          value |= (b & 0x7F) << shift;
          if ((b & 0x80) == 0) break;
          shift += 7;
        }
        if (fieldNum == 5) result['payload_type'] = value;
      } else if (wireType == 2) {
        // Length-delimited
        int len = 0;
        shift = 0;
        while (pos < bytes.length) {
          final b = bytes[pos++];
          len |= (b & 0x7F) << shift;
          if ((b & 0x80) == 0) break;
          shift += 7;
        }
        if (pos + len > bytes.length) break; // malformed
        final data = bytes.sublist(pos, pos + len);
        pos += len;

        switch (fieldNum) {
          case 2:
            result['source_id'] = utf8.decode(data, allowMalformed: true);
          case 3:
            result['destination_id'] = utf8.decode(data, allowMalformed: true);
          case 4:
            result['namespace'] = utf8.decode(data, allowMalformed: true);
          case 7:
            result['payload'] = utf8.decode(data, allowMalformed: true);
        }
      } else {
        // Unknown wire type — stop parsing to avoid corruption
        break;
      }
    }

    return result;
  }
}
