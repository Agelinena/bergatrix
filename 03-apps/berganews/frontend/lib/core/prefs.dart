import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/session.dart';
import '../data/api.dart';
import '../data/models.dart';

/// Preferências da pessoa (painel Aparência), guardadas no servidor: as
/// mesmas abas e o mesmo tema no celular, no computador e na web.
class PrefsController extends AsyncNotifier<Prefs> {
  @override
  Future<Prefs> build() async {
    final logged = ref.watch(sessionProvider.select((s) => s.isLoggedIn));
    if (!logged) return Prefs.defaults;
    try {
      return await ref.read(apiProvider).prefs();
    } on Object {
      // Servidor fora do ar: abre com o padrão em vez de travar.
      return Prefs.defaults;
    }
  }

  /// Só mostra (ex.: enquanto arrasta o tamanho do texto); [save] grava.
  void preview(Prefs prefs) => state = AsyncData(prefs);

  /// Aplica na hora e grava; se o servidor recusar, volta ao que era.
  Future<void> save(Prefs prefs) async {
    final before = state.value;
    state = AsyncData(prefs);
    try {
      state = AsyncData(await ref.read(apiProvider).savePrefs(prefs));
    } on Object {
      if (before != null) state = AsyncData(before);
      rethrow;
    }
  }
}

final prefsProvider = AsyncNotifierProvider<PrefsController, Prefs>(
  PrefsController.new,
);
