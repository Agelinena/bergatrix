import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_error.dart';
import '../../core/platform/app_platform.dart';
import '../../core/storage/key_value_store.dart';
import '../../data/local/database.dart';
import '../../data/models/search_result.dart';
import '../../data/models/stats.dart';
import '../../data/repositories/history_repository.dart';
import '../auth/session.dart';

String _cacheKey(Ref ref) =>
    '${ref.read(appPlatformProvider).simulated ? 'sim_android.' : ''}home.stats';

/// Métricas da tela inicial. Com servidor, busca e guarda a última resposta;
/// sem servidor, mostra a guardada (Passo 10: "cache para uso offline").
final homeStatsProvider = FutureProvider<ListeningStats?>((ref) async {
  final online = ref.watch(sessionProvider.select((s) => s.canUseServer));
  final store = ref.read(keyValueStoreProvider);
  final key = _cacheKey(ref);
  if (online) {
    try {
      final stats = await ref.read(historyRepositoryProvider).stats();
      await store.write(key, jsonEncode(stats.toJson()));
      return stats;
    } on ApiException {
      // Cai no cache abaixo.
    }
  }
  final cached = await store.read(key);
  if (cached == null) return null;
  return ListeningStats.fromJson(jsonDecode(cached) as Map<String, dynamic>);
}, retry: (_, _) => null);

/// "42 h" ou, abaixo de uma hora, "35 min".
String formatListening(int seconds) {
  if (seconds < 3600) return '${(seconds / 60).round()} min';
  return '${(seconds / 3600).round()} h';
}

/// Registra a reprodução no servidor. Sem servidor (ou se falhar), guarda
/// no banco local para enviar ao reconectar (Passo 11).
final playRecorderServiceProvider =
    Provider<Future<void> Function(SearchResult)>(
      (ref) => (track) async {
        final play = PlayRecord(track: track, playedAt: DateTime.now());
        if (ref.read(sessionProvider).canUseServer) {
          try {
            await ref.read(historyRepositoryProvider).record([play]);
            ref.invalidate(homeStatsProvider);
            return;
          } on ApiException catch (e) {
            debugPrint('Histórico fica pendente: ${e.message}');
          }
        }
        await ref
            .read(localDatabaseProvider)
            ?.addPendingPlay(jsonEncode(play.toJson()), play.playedAt);
      },
    );
