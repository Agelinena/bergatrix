import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/app_platform.dart';
import '../../core/storage/key_value_store.dart';

/// Aleatório ligado ou não em cada playlist, guardado no aparelho. Vale
/// para o botão "Aleatório" da playlist e para o do player enquanto ela toca.
final playlistShuffleProvider =
    NotifierProvider.family<PlaylistShuffle, bool, String>(PlaylistShuffle.new);

class PlaylistShuffle extends Notifier<bool> {
  PlaylistShuffle(this.playlistId);

  final String playlistId;

  String get _key =>
      '${ref.read(appPlatformProvider).simulated ? 'sim_android.' : ''}'
      'playlist.shuffle.$playlistId';

  KeyValueStore get _store => ref.read(keyValueStoreProvider);

  @override
  bool build() {
    _load();
    return false;
  }

  Future<void> _load() async {
    final saved = await _store.read(_key);
    if (saved != null && ref.mounted) state = saved == 'true';
  }

  Future<void> set(bool value) async {
    state = value;
    await _store.write(_key, '$value');
  }
}
