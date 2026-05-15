import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Controla se o painel "Fila / Tocando agora" está visível no desktop.
final nowPlayingVisibleProvider = StateProvider<bool>((ref) => false);
