import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'output_engine.dart';
import 'output_platform_io.dart'
    if (dart.library.js_interop) 'output_platform_web.dart';

/// Um Chromecast ou TV achado na rede.
class OutputDevice {
  const OutputDevice({
    required this.id,
    required this.name,
    required this.kind,
    this.host,
    this.port,
    this.data,
  });

  final String id;
  final String name;

  /// "Chromecast" ou "DLNA".
  final String kind;
  final String? host;
  final int? port;

  /// O que a plataforma precisa para conectar (descrição DLNA...).
  final Object? data;
}

/// Procurar e conectar aparelhos na rede (cada plataforma do seu jeito).
abstract interface class OutputPlatform {
  /// Procura na rede local. Na web não dá (o navegador mostra a lista dele
  /// ao conectar): devolve o item "Chromecast" se o navegador tiver Cast.
  Future<List<OutputDevice>> discover();

  Future<RemoteRenderer> connect(OutputDevice device);
}

final outputPlatformProvider = Provider<OutputPlatform>(
  (ref) => createOutputPlatform(),
);

/// Aparelhos achados na última busca (a folha "Tocar em…" busca ao abrir).
class OutputDevicesState {
  const OutputDevicesState({
    this.devices = const [],
    this.searching = false,
    this.connecting,
  });

  final List<OutputDevice> devices;
  final bool searching;

  /// Id do aparelho que está conectando agora.
  final String? connecting;
}

class OutputDevicesController extends Notifier<OutputDevicesState> {
  @override
  OutputDevicesState build() => const OutputDevicesState();

  Future<void> search() async {
    if (state.searching) return;
    state = OutputDevicesState(
      devices: state.devices,
      searching: true,
      connecting: state.connecting,
    );
    List<OutputDevice> found;
    try {
      found = await ref.read(outputPlatformProvider).discover();
    } on Object {
      found = const [];
    }
    if (!ref.mounted) return;
    state = OutputDevicesState(devices: found, connecting: state.connecting);
  }

  /// Conecta; quem chama passa o motor ao player. Lança se não conseguir.
  Future<RemoteRenderer> connect(OutputDevice device) async {
    state = OutputDevicesState(
      devices: state.devices,
      searching: state.searching,
      connecting: device.id,
    );
    try {
      return await ref.read(outputPlatformProvider).connect(device);
    } finally {
      if (ref.mounted) {
        state = OutputDevicesState(
          devices: state.devices,
          searching: state.searching,
        );
      }
    }
  }
}

final outputDevicesProvider =
    NotifierProvider<OutputDevicesController, OutputDevicesState>(
      OutputDevicesController.new,
    );
