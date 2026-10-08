import 'dart:io' show Platform;
import 'dart:math';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/app_platform.dart';
import '../../core/storage/key_value_store.dart';

/// Este aparelho para o "Tocar em…": um id fixo (gerado na primeira vez e
/// guardado no aparelho), um nome para a lista e a plataforma.
class DeviceIdentity {
  const DeviceIdentity({
    required this.id,
    required this.name,
    required this.platform,
  });

  final String id;

  /// Ex.: "Chrome · Linux", "Samsung SM-S911B", nome do PC.
  final String name;

  /// `web`, `android`, `windows`, `linux`, `ios` ou `macos`.
  final String platform;

  Map<String, String> toJson() => {
    'id': id,
    'name': name,
    'platform': platform,
  };
}

final deviceIdentityProvider = FutureProvider<DeviceIdentity>((ref) async {
  final store = ref.watch(keyValueStoreProvider);
  final simulated = ref.watch(appPlatformProvider).simulated;
  final key = '${simulated ? 'sim_android.' : ''}device.id';
  var id = await store.read(key);
  if (id == null || id.isEmpty) {
    final random = Random.secure();
    id = [
      for (var i = 0; i < 16; i++)
        random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
    await store.write(key, id);
  }
  return DeviceIdentity(
    id: id,
    name: await _deviceName(),
    platform: _platform(),
  );
});

String _platform() {
  if (kIsWeb) return 'web';
  return switch (defaultTargetPlatform) {
    TargetPlatform.android => 'android',
    TargetPlatform.windows => 'windows',
    TargetPlatform.linux => 'linux',
    TargetPlatform.iOS => 'ios',
    TargetPlatform.macOS => 'macos',
    _ => 'linux',
  };
}

Future<String> _deviceName() async {
  final info = DeviceInfoPlugin();
  try {
    if (kIsWeb) {
      final web = await info.webBrowserInfo;
      final browser = switch (web.browserName) {
        BrowserName.chrome => 'Chrome',
        BrowserName.firefox => 'Firefox',
        BrowserName.edge => 'Edge',
        BrowserName.safari => 'Safari',
        BrowserName.opera => 'Opera',
        BrowserName.samsungInternet => 'Samsung Internet',
        _ => 'Navegador',
      };
      final system = _systemOf(web.userAgent ?? web.platform ?? '');
      return system == null ? browser : '$browser · $system';
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        final a = await info.androidInfo;
        final brand = a.manufacturer.isEmpty
            ? ''
            : '${a.manufacturer[0].toUpperCase()}${a.manufacturer.substring(1)} ';
        return '$brand${a.model}'.trim();
      case TargetPlatform.windows:
        return (await info.windowsInfo).computerName;
      default:
        return Platform.localHostname;
    }
  } on Object catch (e) {
    debugPrint('Nome do aparelho: $e');
    return switch (_platform()) {
      'web' => 'Navegador',
      'android' => 'Celular',
      _ => 'Computador',
    };
  }
}

/// Sistema pelo user agent (o Chrome do Android diz "Linux" no
/// `navigator.platform`, por isso o Android vem antes).
String? _systemOf(String userAgent) {
  final p = userAgent.toLowerCase();
  if (p.contains('android')) return 'Android';
  if (p.contains('iphone') || p.contains('ipad')) return 'iPhone';
  if (p.contains('windows') || p.startsWith('win')) return 'Windows';
  if (p.contains('mac os') || p.startsWith('mac')) return 'Mac';
  if (p.contains('linux')) return 'Linux';
  return null;
}
