import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Protocolo do Google Cast (CASTV2), sem SDK: TLS na porta 8009, cada
/// mensagem é um `CastMessage` em protobuf precedido do tamanho (4 bytes).
/// Os campos que importam são origem, destino, "namespace" e o JSON.
class CastMessage {
  const CastMessage({
    required this.source,
    required this.destination,
    required this.namespace,
    required this.payload,
  });

  final String source;
  final String destination;
  final String namespace;
  final String payload;

  Map<String, dynamic> get json {
    try {
      return jsonDecode(payload) as Map<String, dynamic>;
    } on Object {
      return const {};
    }
  }

  /// Protobuf: 1 versão (0), 2 origem, 3 destino, 4 namespace, 5 tipo (0 =
  /// texto), 6 o texto.
  Uint8List encode() {
    final out = BytesBuilder()..add(const [0x08, 0x00]);
    void text(int field, String value) {
      final bytes = utf8.encode(value);
      out
        ..addByte(field << 3 | 2)
        ..add(_varint(bytes.length))
        ..add(bytes);
    }

    text(2, source);
    text(3, destination);
    text(4, namespace);
    out.add(const [0x28, 0x00]);
    text(6, payload);
    final body = out.toBytes();
    final framed = ByteData(4)..setUint32(0, body.length);
    return Uint8List.fromList([...framed.buffer.asUint8List(), ...body]);
  }

  static CastMessage decode(Uint8List body) {
    var i = 0;
    int varint() {
      var result = 0;
      var shift = 0;
      while (true) {
        final b = body[i++];
        result |= (b & 0x7f) << shift;
        if (b & 0x80 == 0) return result;
        shift += 7;
      }
    }

    final fields = <int, String>{};
    while (i < body.length) {
      final key = varint();
      final field = key >> 3;
      switch (key & 7) {
        case 0:
          varint();
        case 2:
          final len = varint();
          fields[field] = utf8.decode(
            body.sublist(i, i + len),
            allowMalformed: true,
          );
          i += len;
        default:
          throw const FormatException('tipo de campo desconhecido');
      }
    }
    return CastMessage(
      source: fields[2] ?? '',
      destination: fields[3] ?? '',
      namespace: fields[4] ?? '',
      payload: fields[6] ?? '',
    );
  }

  static List<int> _varint(int value) {
    final out = <int>[];
    var v = value;
    while (v >= 0x80) {
      out.add(v & 0x7f | 0x80);
      v >>= 7;
    }
    out.add(v);
    return out;
  }
}

/// Separa as mensagens que chegam aos pedaços pelo socket.
class CastFrameReader {
  final _buffer = BytesBuilder();

  List<CastMessage> add(List<int> chunk) {
    _buffer.add(chunk);
    final out = <CastMessage>[];
    final data = _buffer.takeBytes();
    var offset = 0;
    while (data.length - offset >= 4) {
      final len = ByteData.sublistView(data, offset, offset + 4).getUint32(0);
      if (data.length - offset - 4 < len) break;
      out.add(CastMessage.decode(data.sublist(offset + 4, offset + 4 + len)));
      offset += 4 + len;
    }
    _buffer.add(data.sublist(offset));
    return out;
  }
}

abstract final class CastNs {
  static const connection = 'urn:x-cast:com.google.cast.tp.connection';
  static const heartbeat = 'urn:x-cast:com.google.cast.tp.heartbeat';
  static const receiver = 'urn:x-cast:com.google.cast.receiver';
  static const media = 'urn:x-cast:com.google.cast.media';
}

/// Conexão com um Chromecast: CONNECT, batimentos (PING/PONG), abrir o
/// receptor de mídia padrão e mandar pedidos com `requestId`.
class CastChannel {
  CastChannel(Stream<List<int>> input, this._write, this._close) {
    _sub = input.listen(
      _onData,
      onDone: _closedNow,
      onError: (Object _) => _closedNow(),
    );
    send(CastNs.connection, {'type': 'CONNECT'});
    _heartbeat = Timer.periodic(heartbeatEvery, (_) {
      if (DateTime.now().difference(_lastSeen) > heartbeatTimeout) {
        close();
        return;
      }
      send(CastNs.heartbeat, {'type': 'PING'});
    });
  }

  /// Conecta por TLS (o Chromecast usa certificado próprio).
  static Future<CastChannel> connect(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final socket = await SecureSocket.connect(
      host,
      port,
      timeout: timeout,
      onBadCertificate: (_) => true,
    );
    return CastChannel(socket, socket.add, socket.destroy);
  }

  static const sender = 'sender-bergastream';
  static const receiverId = 'receiver-0';
  static const heartbeatEvery = Duration(seconds: 5);
  static const heartbeatTimeout = Duration(seconds: 16);

  /// Receptor de mídia padrão do Google (toca uma URL de áudio).
  static const defaultMediaReceiver = 'CC1AD845';

  final void Function(List<int>) _write;
  final void Function() _close;
  late final StreamSubscription<List<int>> _sub;
  late final Timer _heartbeat;
  final _reader = CastFrameReader();
  final _messages = StreamController<CastMessage>.broadcast();
  final _closed = Completer<void>();
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  DateTime _lastSeen = DateTime.now();
  int _nextId = 1;

  Stream<CastMessage> get messages => _messages.stream;
  Future<void> get closed => _closed.future;
  bool get isClosed => _closed.isCompleted;

  void send(
    String namespace,
    Map<String, Object?> payload, {
    String destination = receiverId,
  }) {
    if (isClosed) return;
    _write(
      CastMessage(
        source: sender,
        destination: destination,
        namespace: namespace,
        payload: jsonEncode(payload),
      ).encode(),
    );
  }

  /// Manda com `requestId` e espera a resposta com o mesmo id.
  Future<Map<String, dynamic>> request(
    String namespace,
    Map<String, Object?> payload, {
    String destination = receiverId,
    Duration timeout = const Duration(seconds: 10),
  }) {
    final id = _nextId++;
    final done = _pending[id] = Completer<Map<String, dynamic>>();
    send(namespace, {...payload, 'requestId': id}, destination: destination);
    return done.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(id);
        throw TimeoutException('Chromecast não respondeu');
      },
    );
  }

  void _onData(List<int> chunk) {
    for (final m in _reader.add(chunk)) {
      _lastSeen = DateTime.now();
      final json = m.json;
      if (m.namespace == CastNs.heartbeat) {
        if (json['type'] == 'PING') send(CastNs.heartbeat, {'type': 'PONG'});
        continue;
      }
      if (m.namespace == CastNs.connection && json['type'] == 'CLOSE') {
        // O receptor fechou a conversa (outro aparelho assumiu, app parou).
        if (m.source == receiverId) close();
        _messages.add(m);
        continue;
      }
      final id = json['requestId'];
      if (id is int && id != 0) _pending.remove(id)?.complete(json);
      _messages.add(m);
    }
  }

  void _closedNow() {
    if (isClosed) return;
    _heartbeat.cancel();
    for (final p in _pending.values) {
      p.completeError(const SocketException('Chromecast desconectado'));
    }
    _pending.clear();
    _closed.complete();
    unawaited(_messages.close());
  }

  void close() {
    if (isClosed) return;
    try {
      send(CastNs.connection, {'type': 'CLOSE'});
    } on Object {
      // socket já fechado
    }
    unawaited(_sub.cancel());
    _close();
    _closedNow();
  }
}
