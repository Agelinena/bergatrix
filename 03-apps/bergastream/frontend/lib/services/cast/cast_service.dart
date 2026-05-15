/// Abstract CastService + conditional factory.
///
/// On web (dart.library.html) → cast_service_web.dart (stub)
/// On native (dart.library.io) → cast_service_io.dart (full Cast v2)
library;

import 'cast_types.dart';
export 'cast_types.dart';

import 'cast_service_web.dart'
    if (dart.library.io) 'cast_service_io.dart';

abstract class CastService {
  /// Platform factory — returns the correct implementation.
  factory CastService() = CastServiceImpl;

  /// Discover Chromecast devices on the local network.
  Future<List<CastDevice>> discoverDevices({
    Duration timeout = const Duration(seconds: 5),
  });

  /// Connect to a device and launch the Default Media Receiver app.
  Future<void> connect(CastDevice device);

  /// Send a media URL to the currently connected Cast session.
  Future<void> loadMedia(
    String url,
    String title,
    String artist,
    String? coverUrl,
  );

  Future<void> pause();
  Future<void> resume();

  /// Stop playback and disconnect.
  Future<void> stop();

  void dispose();

  Stream<CastServiceEvent> get events;
}
