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

/// Ordenação das faixas dentro da playlist ("Ordenar por").
enum PlaylistSort {
  playlist('Ordem da playlist', 'Ordem'),
  recentes('Adicionadas por último', 'Recentes'),
  antigas('Adicionadas primeiro', 'Antigas'),
  tituloAz('Título (A–Z)', 'A–Z'),
  tituloZa('Título (Z–A)', 'Z–A'),
  artistaAz('Artista (A–Z)', 'Artista A–Z'),
  artistaZa('Artista (Z–A)', 'Artista Z–A'),
  albumAz('Álbum (A–Z)', 'Álbum A–Z'),
  albumZa('Álbum (Z–A)', 'Álbum Z–A'),
  curtas('Mais curtas primeiro', 'Curtas'),
  longas('Mais longas primeiro', 'Longas');

  const PlaylistSort(this.label, this.short);

  /// Na lista "Ordenar por".
  final String label;

  /// No botão ao lado da busca.
  final String short;
}

/// Ordenação escolhida em cada playlist (vale enquanto o app está aberto).
final playlistSortProvider =
    NotifierProvider.family<PlaylistSortChoice, PlaylistSort, String>(
      PlaylistSortChoice.new,
    );

class PlaylistSortChoice extends Notifier<PlaylistSort> {
  PlaylistSortChoice(this.playlistId);

  final String playlistId;

  @override
  PlaylistSort build() => PlaylistSort.playlist;

  void set(PlaylistSort sort) => state = sort;
}

/// Filtra (título, artista ou álbum) e ordena as faixas da playlist.
/// Empates mantêm a ordem da playlist.
List<PlaylistTrack> sortAndFilter(
  List<PlaylistTrack> tracks,
  PlaylistSort sort,
  String query,
) {
  final q = query.trim().toLowerCase();
  final filtered = [
    for (final t in tracks)
      if (q.isEmpty ||
          '${t.title} ${t.artist} ${t.album}'.toLowerCase().contains(q))
        t,
  ];
  int text(String a, String b) => a.toLowerCase().compareTo(b.toLowerCase());
  int added(PlaylistTrack a, PlaylistTrack b) {
    final da = DateTime.tryParse(a.addedAt);
    final db = DateTime.tryParse(b.addedAt);
    if (da == null || db == null) return a.position.compareTo(b.position);
    return da.compareTo(db);
  }

  final int Function(PlaylistTrack, PlaylistTrack) compare = switch (sort) {
    PlaylistSort.playlist => (a, b) => 0,
    PlaylistSort.recentes => (a, b) => added(b, a),
    PlaylistSort.antigas => added,
    PlaylistSort.tituloAz => (a, b) => text(a.title, b.title),
    PlaylistSort.tituloZa => (a, b) => text(b.title, a.title),
    PlaylistSort.artistaAz => (a, b) {
      final c = text(a.artist, b.artist);
      return c != 0 ? c : text(a.title, b.title);
    },
    PlaylistSort.artistaZa => (a, b) {
      final c = text(b.artist, a.artist);
      return c != 0 ? c : text(a.title, b.title);
    },
    PlaylistSort.albumAz => (a, b) => text(a.album, b.album),
    PlaylistSort.albumZa => (a, b) => text(b.album, a.album),
    PlaylistSort.curtas => (a, b) => a.durationSeconds.compareTo(
      b.durationSeconds,
    ),
    PlaylistSort.longas => (a, b) => b.durationSeconds.compareTo(
      a.durationSeconds,
    ),
  };
  filtered.sort((a, b) {
    final c = compare(a, b);
    return c != 0 ? c : a.position.compareTo(b.position);
  });
  return filtered;
}
