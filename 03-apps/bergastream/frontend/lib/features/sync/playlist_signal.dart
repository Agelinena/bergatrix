import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Aviso do servidor "estas playlists mudaram" (chega pelo WebSocket dos
/// aparelhos). A sincronização ouve e busca de novo o que estiver na tela.
final playlistsChangedSignalProvider = Provider<StreamController<List<String>>>(
  (ref) {
    final controller = StreamController<List<String>>.broadcast();
    ref.onDispose(controller.close);
    return controller;
  },
);
