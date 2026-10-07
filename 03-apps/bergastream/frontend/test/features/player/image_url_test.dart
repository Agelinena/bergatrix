import 'package:bergastream/features/player/player_texts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fora da web a URL da capa não muda', () {
    const url = 'https://i.scdn.co/image/abc';
    expect(webImageUrl(url), url);
  });

  test('imageFor aceita nulo, arquivo e URL', () {
    expect(imageFor(null), isNull);
    expect(imageFor('file:///tmp/capa.jpg'), isNotNull);
    expect(imageFor('https://i.scdn.co/image/abc'), isNotNull);
  });

  test('na web a capa passa pelo proxy com a URL codificada', () {
    expect(
      webImageUrl('https://i.scdn.co/image/a?b=1&c=2', web: true),
      '/api/images?url=https%3A%2F%2Fi.scdn.co%2Fimage%2Fa%3Fb%3D1%26c%3D2',
    );
    // Caminhos do próprio servidor e http simples não passam pelo proxy.
    expect(
      webImageUrl('/api/playlists/1/cover', web: true),
      '/api/playlists/1/cover',
    );
    expect(webImageUrl('http://x/y.jpg', web: true), 'http://x/y.jpg');
  });
}
