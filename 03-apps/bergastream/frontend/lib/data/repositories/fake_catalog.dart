import '../models/playlist.dart';
import '../models/track.dart';

/// Dados fictícios idênticos aos do protótipo (`docs/design/bergastream_preview.html`).
/// Usados até os repositórios reais (Passos 3 e 4).
abstract final class FakeCatalog {
  static const tracks = [
    Track(
      id: 't1',
      title: 'Blinding Lights',
      artist: 'The Weeknd',
      album: 'After Hours',
      durationSeconds: 200,
    ),
    Track(
      id: 't2',
      title: 'Levitating',
      artist: 'Dua Lipa',
      album: 'Future Nostalgia',
      durationSeconds: 203,
    ),
    Track(
      id: 't3',
      title: 'Bohemian Rhapsody',
      artist: 'Queen',
      album: 'A Night at the Opera',
      durationSeconds: 355,
    ),
    Track(
      id: 't4',
      title: 'Smells Like Teen Spirit',
      artist: 'Nirvana',
      album: 'Nevermind',
      durationSeconds: 301,
    ),
    Track(
      id: 't5',
      title: 'Hotel California',
      artist: 'Eagles',
      album: 'Hotel California',
      durationSeconds: 390,
    ),
    Track(
      id: 't6',
      title: 'Get Lucky',
      artist: 'Daft Punk',
      album: 'Random Access Memories',
      durationSeconds: 369,
    ),
    Track(
      id: 't7',
      title: 'Creep',
      artist: 'Radiohead',
      album: 'Pablo Honey',
      durationSeconds: 238,
    ),
    Track(
      id: 't8',
      title: 'Redbone',
      artist: 'Childish Gambino',
      album: 'Awaken, My Love!',
      durationSeconds: 327,
    ),
  ];

  /// Artistas da tela inicial (as 6 primeiras faixas).
  static List<String> get topArtists => [
    for (final t in tracks.take(6)) t.artist,
  ];

  /// "Mais tocadas" da tela inicial.
  static List<Track> get mostPlayed => [
    tracks[0],
    tracks[2],
    tracks[5],
    tracks[7],
  ];

  /// Álbuns da tela inicial (faixas 3 a 8).
  static List<Track> get topAlbums => tracks.sublist(2);

  static const recentSearches = ['daft punk', 'queen', 'lofi para estudar'];

  static const playlists = [
    PlaylistSummary(id: 'p1', name: 'Roadtrip', trackCount: 5, peopleCount: 3),
    PlaylistSummary(id: 'p2', name: 'Foco', trackCount: 12, peopleCount: 1),
  ];
}
