import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api.dart';
import '../data/models.dart';
import '../sync/sync_controller.dart';

/// Preferências: a cópia do banco local aparece na hora (offline também), e a
/// do servidor substitui quando chega.
final prefsProvider = AsyncNotifierProvider<PrefsController, Prefs>(PrefsController.new);

class PrefsController extends AsyncNotifier<Prefs> {
  static const _key = 'prefs';

  @override
  Future<Prefs> build() async {
    final store = ref.watch(storeProvider);
    final cached = store.meta(_key);
    final local = cached == null ? null : Prefs.fromJson(jsonDecode(cached) as Json);
    Future.microtask(_refresh);
    return local ?? Prefs.fallback;
  }

  Future<void> _refresh() async {
    try {
      _keep(await ref.read(apiProvider).prefs());
    } on Object {
      // Sem conexão: fica a cópia local.
    }
  }

  void _keep(Prefs prefs, [Json? raw]) {
    state = AsyncData(prefs);
    ref.read(storeProvider).setMeta(_key, jsonEncode(raw ?? _toJson(prefs)));
  }

  Json _toJson(Prefs p) => {
    'tabs': [
      for (final t in p.tabs) {'id': t.id.name, 'enabled': t.enabled, 'available': t.available},
    ],
    'theme': p.theme,
    'default_spaces': p.defaultSpaces,
    'notify_hour': p.notifyHour,
    'week_start': p.weekStart,
  };

  /// Salva no servidor (precisa de conexão).
  Future<void> save(Json changes) async {
    _keep(await ref.read(apiProvider).savePrefs(changes));
  }
}
