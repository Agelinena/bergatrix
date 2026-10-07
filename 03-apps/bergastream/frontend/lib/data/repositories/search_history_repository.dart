import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/app_platform.dart';
import '../../core/storage/key_value_store.dart';

/// Histórico de buscas (Seção 6.3: "Buscas recentes"): mais recentes
/// primeiro, sem repetir (ignorando maiúsculas), no máximo [limit] termos.
/// Fica no armazenamento local; no Passo 9 migra para o banco local.
class SearchHistory extends Notifier<List<String>> {
  static const limit = 10;

  String get _key =>
      '${ref.read(appPlatformProvider).simulated ? 'sim_android.' : ''}search_history';

  KeyValueStore get _store => ref.read(keyValueStoreProvider);

  @override
  List<String> build() {
    _load();
    return const [];
  }

  Future<void> _load() async {
    final raw = await _store.read(_key);
    if (raw == null) return;
    try {
      state = [for (final t in jsonDecode(raw) as List<dynamic>) t as String];
    } on FormatException {
      state = const [];
    }
  }

  Future<void> add(String term) async {
    final clean = term.trim();
    if (clean.isEmpty) return;
    state = [
      clean,
      for (final t in state)
        if (t.toLowerCase() != clean.toLowerCase()) t,
    ].take(limit).toList();
    await _store.write(_key, jsonEncode(state));
  }

  Future<void> remove(String term) async {
    state = [
      for (final t in state)
        if (t != term) t,
    ];
    await _store.write(_key, jsonEncode(state));
  }
}

final searchHistoryProvider = NotifierProvider<SearchHistory, List<String>>(
  SearchHistory.new,
);
