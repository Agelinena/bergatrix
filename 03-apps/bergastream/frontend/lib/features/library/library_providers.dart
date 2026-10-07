import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/playlist_models.dart';
import '../auth/session.dart';

export '../playlists/playlist_store.dart'
    show myPlaylistsProvider, playlistDetailProvider;
import '../player/player_texts.dart';

/// Imagem do servidor a partir de caminho relativo (`/api/...`).
ImageProvider? serverImage(WidgetRef ref, String? path) {
  if (path == null) return null;
  if (path.startsWith('http')) return imageFor(path);
  final server = ref.read(sessionProvider).server ?? '';
  return NetworkImage('$server$path');
}

/// "N músicas · M pessoas" ou "N músicas · só você" (Seção 6.4).
String playlistSubtitle({required int tracks, required int people}) {
  final t = tracks == 1 ? '1 música' : '$tracks músicas';
  final p = people <= 1 ? 'só você' : '$people pessoas';
  return '$t · $p';
}

/// Ordenação da lista (chip que alterna a cada toque).
enum PlaylistSort {
  adicao('Adição'),
  az('A–Z'),
  artista('Artista');

  const PlaylistSort(this.label);

  final String label;

  PlaylistSort get next => values[(index + 1) % values.length];
}

/// Filtra (título ou artista) e ordena as faixas da playlist.
List<PlaylistTrack> sortAndFilter(
  List<PlaylistTrack> tracks,
  PlaylistSort sort,
  String query,
) {
  final q = query.trim().toLowerCase();
  final filtered = [
    for (final t in tracks)
      if (q.isEmpty || '${t.title} ${t.artist}'.toLowerCase().contains(q)) t,
  ];
  int byText(String a, String b) => a.toLowerCase().compareTo(b.toLowerCase());
  switch (sort) {
    case PlaylistSort.adicao:
      filtered.sort((a, b) => a.position.compareTo(b.position));
    case PlaylistSort.az:
      filtered.sort((a, b) => byText(a.title, b.title));
    case PlaylistSort.artista:
      filtered.sort((a, b) {
        final c = byText(a.artist, b.artist);
        return c != 0 ? c : byText(a.title, b.title);
      });
  }
  return filtered;
}
