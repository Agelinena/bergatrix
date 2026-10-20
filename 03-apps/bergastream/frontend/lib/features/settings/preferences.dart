import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/app_platform.dart';
import '../../core/storage/key_value_store.dart';

/// Qualidade do áudio pedida ao servidor (Seção 6.5). O servidor guarda um
/// arquivo por música (o melhor que conseguiu) e entrega neste nível — nunca
/// acima do que tem: pedindo Original de uma música que só existe em 320,
/// vem o 320.
enum AudioQuality {
  original('Original', 'FLAC quando houver', 'original'),
  alta('Alta', '320 kbps', 'high'),
  normal('Normal', '160 kbps', 'normal'),
  economica('Econômica', '96 kbps', 'low');

  const AudioQuality(this.label, this.detail, this.api);

  final String label;
  final String detail;

  /// Valor de `?quality=` na API.
  final String api;
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
    this.wifiQuality = AudioQuality.original,
    this.mobileQuality = AudioQuality.normal,
    this.offlineQuality = AudioQuality.alta,
    this.autoDownloadNew = false,
    this.theme = AppTheme.sistema,
    this.pauseFadeMs = 300,
    this.trackFadeMs = 0,
    this.volume = 1,
    this.normalizeVolume = true,
  });

  /// Fade ao pausar e ao voltar a tocar (0 = sem fade).
  final int pauseFadeMs;

  /// Fade na troca de música: desce no fim de uma e sobe no começo da
  /// próxima (0 = desligado).
  final int trackFadeMs;

  /// Volume do player (barra de volume no computador e na web).
  final double volume;

  /// Abaixa as músicas mais altas para todas soarem parecidas.
  final bool normalizeVolume;

  /// Streaming no Wi-Fi (ou cabo) e na web.
  final AudioQuality wifiQuality;

  /// Streaming em dados móveis.
  final AudioQuality mobileQuality;

  /// Músicas baixadas no aparelho; mudar troca as cópias já baixadas.
  final AudioQuality offlineQuality;

  /// "Baixar novas músicas das playlists automaticamente" (padrão: não).
  final bool autoDownloadNew;
  final AppTheme theme;

  Preferences copyWith({
    AudioQuality? wifiQuality,
    AudioQuality? mobileQuality,
    AudioQuality? offlineQuality,
    bool? autoDownloadNew,
    AppTheme? theme,
    int? pauseFadeMs,
    int? trackFadeMs,
    double? volume,
    bool? normalizeVolume,
  }) => Preferences(
    wifiQuality: wifiQuality ?? this.wifiQuality,
    mobileQuality: mobileQuality ?? this.mobileQuality,
    offlineQuality: offlineQuality ?? this.offlineQuality,
    autoDownloadNew: autoDownloadNew ?? this.autoDownloadNew,
    theme: theme ?? this.theme,
    pauseFadeMs: pauseFadeMs ?? this.pauseFadeMs,
    trackFadeMs: trackFadeMs ?? this.trackFadeMs,
    volume: volume ?? this.volume,
    normalizeVolume: normalizeVolume ?? this.normalizeVolume,
  );
}

/// Preferências guardadas no aparelho (funciona também na web).
class PreferencesNotifier extends Notifier<Preferences> {
  String _key(String name) =>
      '${ref.read(appPlatformProvider).simulated ? 'sim_android.' : ''}prefs.$name';

  KeyValueStore get _store => ref.read(keyValueStoreProvider);

  /// Completa quando o que estava guardado foi lido (antes disso o estado
  /// é o padrão). Quem compara com a preferência salva espera por ele.
  late Future<void> ready;

  @override
  Preferences build() {
    ready = _load();
    return const Preferences();
  }

  Future<void> _load() async {
    // Captura antes das esperas: o provider pode ser descartado no meio.
    final store = _store;
    final prefix = _key('');
    Future<String?> read(String name) => store.read('$prefix$name');
    final wifi = await read('quality_wifi');
    final mobile = await read('quality_mobile');
    final offline = await read('quality_offline');
    // Versões antigas tinham uma "qualidade de streaming" só (alta/normal/
    // baixa): vira a de dados móveis.
    final legacy = await read('quality');
    final auto = await read('auto_download_new');
    final theme = await read('theme');
    final pauseFade = int.tryParse(await read('pause_fade_ms') ?? '');
    final trackFade = int.tryParse(await read('track_fade_ms') ?? '');
    final volume = double.tryParse(await read('volume') ?? '');
    final normalize = await read('normalize_volume');
    if (!ref.mounted) return;
    state = Preferences(
      pauseFadeMs: pauseFade ?? 300,
      trackFadeMs: trackFade ?? 0,
      volume: (volume ?? 1).clamp(0.0, 1.0),
      normalizeVolume: normalize != 'false',
      wifiQuality: _quality(wifi, AudioQuality.original),
      mobileQuality: _quality(
        mobile ?? (legacy == 'baixa' ? 'economica' : legacy),
        AudioQuality.normal,
      ),
      offlineQuality: _quality(offline, AudioQuality.alta),
      autoDownloadNew: auto == 'true',
      theme: AppTheme.values.firstWhere(
        (t) => t.name == theme,
        orElse: () => AppTheme.sistema,
      ),
    );
  }

  static AudioQuality _quality(String? name, AudioQuality fallback) =>
      AudioQuality.values.firstWhere(
        (q) => q.name == name,
        orElse: () => fallback,
      );

  Future<void> setWifiQuality(AudioQuality quality) async {
    state = state.copyWith(wifiQuality: quality);
    await _store.write(_key('quality_wifi'), quality.name);
  }

  Future<void> setMobileQuality(AudioQuality quality) async {
    state = state.copyWith(mobileQuality: quality);
    await _store.write(_key('quality_mobile'), quality.name);
  }

  /// Muda a qualidade das músicas baixadas; quem chama pede ao gerenciador
  /// de downloads para trocar as cópias (ver DownloadManager.refreshQuality).
  Future<void> setOfflineQuality(AudioQuality quality) async {
    state = state.copyWith(offlineQuality: quality);
    await _store.write(_key('quality_offline'), quality.name);
  }

  Future<void> setAutoDownloadNew(bool value) async {
    state = state.copyWith(autoDownloadNew: value);
    await _store.write(_key('auto_download_new'), '$value');
  }

  Future<void> setPauseFade(int ms) async {
    state = state.copyWith(pauseFadeMs: ms);
    await _store.write(_key('pause_fade_ms'), '$ms');
  }

  Future<void> setTrackFade(int ms) async {
    state = state.copyWith(trackFadeMs: ms);
    await _store.write(_key('track_fade_ms'), '$ms');
  }

  /// [save] falso enquanto arrasta a barra (grava só ao soltar).
  Future<void> setVolume(double volume, {bool save = true}) async {
    state = state.copyWith(volume: volume.clamp(0.0, 1.0));
    if (save) {
      await _store.write(_key('volume'), state.volume.toStringAsFixed(3));
    }
  }

  Future<void> setNormalizeVolume(bool value) async {
    state = state.copyWith(normalizeVolume: value);
    await _store.write(_key('normalize_volume'), '$value');
  }

  Future<void> setTheme(AppTheme theme) async {
    state = state.copyWith(theme: theme);
    await _store.write(_key('theme'), theme.name);
  }
}

final preferencesProvider = NotifierProvider<PreferencesNotifier, Preferences>(
  PreferencesNotifier.new,
);
