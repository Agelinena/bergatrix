import 'package:flutter/material.dart' show ThemeMode;
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

/// Aparência: seguir o sistema, sempre claro ou sempre escuro.
enum AppTheme {
  sistema('Sistema', ThemeMode.system),
  claro('Claro', ThemeMode.light),
  escuro('Escuro', ThemeMode.dark);

  const AppTheme(this.label, this.mode);

  final String label;
  final ThemeMode mode;
}

class Preferences {
  const Preferences({
    this.quality = StreamQuality.alta,
    this.autoDownloadNew = false,
    this.theme = AppTheme.sistema,
  });

  final StreamQuality quality;

  /// "Baixar novas músicas das playlists automaticamente" (padrão: não).
  final bool autoDownloadNew;
  final AppTheme theme;

  Preferences copyWith({
    StreamQuality? quality,
    bool? autoDownloadNew,
    AppTheme? theme,
  }) => Preferences(
    quality: quality ?? this.quality,
    autoDownloadNew: autoDownloadNew ?? this.autoDownloadNew,
    theme: theme ?? this.theme,
  );
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
    final theme = await _store.read(_key('theme'));
    state = Preferences(
      quality: StreamQuality.values.firstWhere(
        (q) => q.name == quality,
        orElse: () => StreamQuality.alta,
      ),
      autoDownloadNew: auto == 'true',
      theme: AppTheme.values.firstWhere(
        (t) => t.name == theme,
        orElse: () => AppTheme.sistema,
      ),
    );
  }

  Future<void> setQuality(StreamQuality quality) async {
    state = state.copyWith(quality: quality);
    await _store.write(_key('quality'), quality.name);
  }

  Future<void> setAutoDownloadNew(bool value) async {
    state = state.copyWith(autoDownloadNew: value);
    await _store.write(_key('auto_download_new'), '$value');
  }

  Future<void> setTheme(AppTheme theme) async {
    state = state.copyWith(theme: theme);
    await _store.write(_key('theme'), theme.name);
  }
}

final preferencesProvider = NotifierProvider<PreferencesNotifier, Preferences>(
  PreferencesNotifier.new,
);
