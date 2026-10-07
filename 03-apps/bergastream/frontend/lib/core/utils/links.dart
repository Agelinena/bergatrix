import '../../data/models/search_result.dart';

/// Texto colado que parece link (começa com http) — Seção 6.3.
bool isLink(String text) =>
    RegExp(r'^https?://', caseSensitive: false).hasMatch(text.trim());

/// Origem de um link de música, para o rótulo do cartão.
String? linkSource(String url) {
  final u = url.toLowerCase();
  if (u.contains('spotify.com') || u.startsWith('spotify:')) return 'Spotify';
  if (u.contains('deezer.com') || u.contains('deezer.page.link')) {
    return 'Deezer';
  }
  if (u.contains('youtube.com') || u.contains('youtu.be')) return 'YouTube';
  return null;
}

/// Link público da faixa no serviço de origem (compartilhar).
({String label, String url})? externalLinkFor(SearchResult t) =>
    switch (t.provider) {
      'spotify' => (
        label: 'Link do Spotify',
        url: 'https://open.spotify.com/track/${t.externalId}',
      ),
      'deezer' => (
        label: 'Link do Deezer',
        url: 'https://www.deezer.com/track/${t.externalId}',
      ),
      'ytmusic' => (
        label: 'Link do YouTube Music',
        url: 'https://music.youtube.com/watch?v=${t.externalId}',
      ),
      'youtube' => (
        label: 'Link do YouTube',
        url: 'https://www.youtube.com/watch?v=${t.externalId}',
      ),
      _ => null,
    };

/// Link do app: abre a Busca do servidor já com o link da faixa, que o app
/// resolve para a música exata.
String appLinkFor(String server, String externalUrl) =>
    '$server/#/buscar?link=${Uri.encodeComponent(externalUrl)}';
