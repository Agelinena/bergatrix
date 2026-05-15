import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/api_client.dart';

/// Mantém o conjunto de IDs de tracks curtidas pelo usuário atual.
/// Carregado uma vez no startup e atualizado otimisticamente a cada toggle.
final likedProvider = NotifierProvider<LikedNotifier, Set<String>>(
  LikedNotifier.new,
);

class LikedNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() {
    // Carrega assincronamente após build() retornar
    Future.microtask(_load);
    return {};
  }

  Future<void> _load() async {
    try {
      final client = ref.read(apiClientProvider);
      final data = await client.getLikedTracks();
      final ids = data.map((t) => (t as Map<String, dynamic>)['id'] as String).toSet();
      state = ids;
    } catch (_) {}
  }

  Future<void> reload() => _load();

  bool isLiked(String trackId) => state.contains(trackId);

  /// Toggle curtida — atualização otimista: atualiza UI imediatamente,
  /// reverte em caso de erro.
  Future<void> toggle(String trackId) async {
    final client = ref.read(apiClientProvider);
    final wasLiked = state.contains(trackId);

    // Otimismo: atualiza antes da confirmação da API
    state = wasLiked
        ? (Set.from(state)..remove(trackId))
        : (Set.from(state)..add(trackId));

    try {
      if (wasLiked) {
        await client.unlikeTrack(trackId);
      } else {
        await client.likeTrack(trackId);
      }
    } catch (_) {
      // Reverte em caso de erro de rede
      state = wasLiked
          ? (Set.from(state)..add(trackId))
          : (Set.from(state)..remove(trackId));
    }
  }
}
