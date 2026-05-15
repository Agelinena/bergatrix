/// Web stub for CastService.
/// Discovery / protocol sockets are not available in the browser sandbox.
/// Chrome already exposes a native Cast button in the toolbar.
library;

import 'dart:async';
import 'cast_service.dart';
import 'cast_types.dart';

class CastServiceImpl implements CastService {
  final _events = StreamController<CastServiceEvent>.broadcast();

  @override
  Stream<CastServiceEvent> get events => _events.stream;

  @override
  Future<List<CastDevice>> discoverDevices({
    Duration timeout = const Duration(seconds: 5),
  }) async =>
      []; // mDNS UDP multicast not available in browser sandbox

  @override
  Future<void> connect(CastDevice device) async {
    _events.add(const CastEventError('Não suportado no navegador. Use o botão Cast nativo do Chrome.'));
  }

  @override
  Future<void> loadMedia(String url, String title, String artist, String? coverUrl) async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> resume() async {}

  @override
  Future<void> stop() async {
    _events.add(const CastEventDisconnected());
  }

  @override
  void dispose() => _events.close();
}
