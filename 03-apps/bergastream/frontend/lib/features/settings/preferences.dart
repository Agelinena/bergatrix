import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/app_platform.dart';
import '../../core/storage/key_value_store.dart';

/// Qualidade de streaming (Seção 6.5).
enum StreamQuality {
  alta('Alta (320 kbps)'),
  normal('Normal (160 kbps)'),
  baixa('Baixa (96 kbps)');

  const StreamQuality(this.label);

  final String label;
}

class Preferences {
  const Preferences({
    this.quality = StreamQuality.alta,
    this.autoDownloadNew = false,
  });

  final StreamQuality quality;

  /// "Baixar novas músicas das playlists automaticamente" (padrão: não).
  final bool autoDownloadNew;
}

/// Preferências guardadas no aparelho (funciona também na web).
class PreferencesNotifier extends Notifier<Preferences> {
  String _key(String name) =>
      '${ref.read(appPlatformProvider).simulated ? 'sim_android.' : ''}prefs.$name';

  KeyValueStore get _store => ref.read(keyValueStoreProvider);

  @override
  Preferences build() {
    _load();
    return const Preferences();
  }

  Future<void> _load() async {
    final quality = await _store.read(_key('quality'));
    final auto = await _store.read(_key('auto_download_new'));
    state = Preferences(
      quality: StreamQuality.values.firstWhere(
        (q) => q.name == quality,
        orElse: () => StreamQuality.alta,
      ),
      autoDownloadNew: auto == 'true',
    );
  }

  Future<void> setQuality(StreamQuality quality) async {
    state = Preferences(
      quality: quality,
      autoDownloadNew: state.autoDownloadNew,
    );
    await _store.write(_key('quality'), quality.name);
  }

  Future<void> setAutoDownloadNew(bool value) async {
    state = Preferences(quality: state.quality, autoDownloadNew: value);
    await _store.write(_key('auto_download_new'), '$value');
  }
}

final preferencesProvider = NotifierProvider<PreferencesNotifier, Preferences>(
  PreferencesNotifier.new,
);
