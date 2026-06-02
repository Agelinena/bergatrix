/// User-tweakable playback options: currently the crossfade duration
/// (0 = disabled, otherwise milliseconds of fade-out + fade-in between
/// consecutive tracks).  Persisted via [AppStorage] so the setting
/// survives restarts.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/storage.dart';

class PlaybackSettings {
  /// Crossfade duration in milliseconds.  0 = disabled.  Range [0, 12000].
  final int crossfadeMs;

  const PlaybackSettings({this.crossfadeMs = 0});

  PlaybackSettings copyWith({int? crossfadeMs}) =>
      PlaybackSettings(crossfadeMs: crossfadeMs ?? this.crossfadeMs);
}

class PlaybackSettingsNotifier extends StateNotifier<PlaybackSettings> {
  PlaybackSettingsNotifier() : super(const PlaybackSettings()) {
    _load();
  }

  static const _kCrossfadeKey = 'crossfade_ms';
  static const maxCrossfadeMs = 12000;

  Future<void> _load() async {
    try {
      final ms = await AppStorage.getInt(_kCrossfadeKey);
      if (ms != null) {
        state = state.copyWith(
          crossfadeMs: ms.clamp(0, maxCrossfadeMs),
        );
      }
    } catch (e) {
      debugPrint('[PlaybackSettings] load error: $e');
    }
  }

  Future<void> setCrossfadeMs(int ms) async {
    final clamped = ms.clamp(0, maxCrossfadeMs);
    state = state.copyWith(crossfadeMs: clamped);
    try {
      await AppStorage.setInt(_kCrossfadeKey, clamped);
    } catch (e) {
      debugPrint('[PlaybackSettings] save error: $e');
    }
  }
}

final playbackSettingsProvider =
    StateNotifierProvider<PlaybackSettingsNotifier, PlaybackSettings>(
  (ref) => PlaybackSettingsNotifier(),
);
