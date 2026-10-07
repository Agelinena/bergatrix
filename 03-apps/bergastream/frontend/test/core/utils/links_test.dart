import 'package:bergastream/core/utils/links.dart';
import 'package:bergastream/data/models/search_result.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('detecta link colado', () {
    expect(isLink('https://open.spotify.com/track/x'), isTrue);
    expect(isLink('  HTTP://youtu.be/x '), isTrue);
    expect(isLink('queen'), isFalse);
    expect(isLink('spotify.com/track/x'), isFalse);
  });

  test('origem do link', () {
    expect(linkSource('https://open.spotify.com/playlist/x'), 'Spotify');
    expect(linkSource('https://www.deezer.com/album/1'), 'Deezer');
    expect(linkSource('https://youtu.be/abc'), 'YouTube');
    expect(linkSource('https://example.com'), isNull);
  });

  SearchResult t(String provider) => SearchResult(
    provider: provider,
    externalId: 'ID1',
    title: 'T',
    artist: 'A',
  );

  test('link externo por origem', () {
    expect(
      externalLinkFor(t('spotify'))!.url,
      'https://open.spotify.com/track/ID1',
    );
    expect(externalLinkFor(t('spotify'))!.label, 'Link do Spotify');
    expect(
      externalLinkFor(t('deezer'))!.url,
      'https://www.deezer.com/track/ID1',
    );
    expect(
      externalLinkFor(t('ytmusic'))!.url,
      'https://music.youtube.com/watch?v=ID1',
    );
    expect(externalLinkFor(t('youtube'))!.label, 'Link do YouTube');
  });

  test('link do app abre a Busca com o link da faixa', () {
    expect(
      appLinkFor('https://musica.com', 'https://open.spotify.com/track/ID1'),
      'https://musica.com/#/buscar?link=https%3A%2F%2Fopen.spotify.com%2Ftrack%2FID1',
    );
  });
}
