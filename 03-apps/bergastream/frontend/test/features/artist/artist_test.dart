import 'package:bergastream/app/routes.dart';
import 'package:bergastream/core/utils/format.dart';
import 'package:bergastream/data/repositories/catalog_repository.dart';
import 'package:bergastream/features/album/album_screen.dart';
import 'package:bergastream/features/artist/artist_screen.dart';
import 'package:bergastream/features/artist/artist_tracks_pager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../app_harness.dart';
import '../../helpers.dart';

void main() {
  group('paginação de "Todas as músicas"', () {
    late FakeCatalogRepository repo;
    late ProviderContainer c;
    setUp(() {
      repo = FakeCatalogRepository(totalTracks: 120);
      c = ProviderContainer(
        overrides: [catalogRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(c.dispose);
    });

    const key = ('spotify', 'banda');
    ArtistTracksPager pager() => c.read(artistTracksProvider(key).notifier);
    ArtistTracksState state() => c.read(artistTracksProvider(key));

    test('carrega páginas seguidas sem repetir e para quando acabam', () async {
      final sub = c.listen(artistTracksProvider(key), (_, _) {});
      addTearDown(sub.close);
      await pager().loadMore();
      expect(state().items, hasLength(50));
      await pager().loadMore();
      await pager().loadMore();
      expect(state().items, hasLength(120));
      expect(state().items.map((t) => t.id).toSet(), hasLength(120));
      expect(state().hasMore, isFalse);
      await pager().loadMore();
      expect(repo.requestedOffsets, [0, 50, 100]);
    });

    test('pedidos simultâneos viram um só', () async {
      final sub = c.listen(artistTracksProvider(key), (_, _) {});
      addTearDown(sub.close);
      await Future.wait([pager().loadMore(), pager().loadMore()]);
      expect(repo.requestedOffsets, [0]);
    });

    test('erro mantém o que já carregou e "tentar de novo" continua', () async {
      final sub = c.listen(artistTracksProvider(key), (_, _) {});
      addTearDown(sub.close);
      repo.failPageAt = 50;
      await pager().loadMore();
      await pager().loadMore();
      expect(state().error, isNotNull);
      expect(state().items, hasLength(50));
      await pager().loadMore();
      expect(state().error, isNull);
      expect(state().items, hasLength(100));
    });
  });

  test('filtro por título, artista ou álbum', () {
    final tracks = [
      FakeCatalogRepository.track(1),
      FakeCatalogRepository.track(2, album: 'Ao Vivo'),
    ];
    expect(filterTracks(tracks, 'faixa 2'), hasLength(1));
    expect(filterTracks(tracks, 'ao vivo'), hasLength(1));
    expect(filterTracks(tracks, ''), hasLength(2));
  });

  test('formatos', () {
    expect(compactCount(950), '950');
    expect(compactCount(12345), '12,3 mil');
    expect(compactCount(58676791), '58,7 mi');
    expect(compactCount(2000000), '2 mi');
    expect(totalDuration([1800, 60]), '31 min');
    expect(totalDuration([3600, 300]), '1 h 05 min');
  });

  test('artista/álbum abrem dentro da aba atual', () {
    expect(
      AppRoutes.artistOf('/buscar/link', 'spotify', 'x'),
      '/buscar/artista/spotify/x',
    );
    expect(
      AppRoutes.albumOf('/inicio', 'ytmusic', 'MPREb_1'),
      '/inicio/album/ytmusic/MPREb_1',
    );
    expect(AppRoutes.tabOf('/ajustes'), '/inicio');
  });

  testWidgets('artista: populares, álbuns e todas as músicas até o fim', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = FakeCatalogRepository(totalTracks: 120);
    await tester.pumpWidget(
      wrap(
        const ArtistScreen(provider: 'spotify', id: 'banda'),
        catalog: repo,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Banda'), findsWidgets);
    expect(find.text('1,2 mi de seguidores'), findsOneWidget);
    expect(find.text('Faixa 0'), findsOneWidget);

    await tester.tap(find.text('Álbuns'));
    await tester.pumpAndSettle();
    expect(find.text('Álbum 2 · 2022'), findsOneWidget);

    await tester.tap(find.text('Todas as músicas'));
    await tester.pumpAndSettle();
    expect(find.text('50 de 120 músicas'), findsOneWidget);
    // Rola até o fim várias vezes: carrega as páginas seguintes.
    for (var i = 0; i < 6; i++) {
      await tester.drag(find.byType(ListView), const Offset(0, -4000));
      await tester.pumpAndSettle();
    }
    expect(repo.requestedOffsets, [0, 50, 100]);
    expect(find.text('Faixa 119'), findsOneWidget);
    expect(find.text('Carregar mais'), findsNothing);
    // Volta ao topo: o contador mostra tudo carregado.
    await tester.drag(find.byType(ListView), const Offset(0, 30000));
    await tester.pumpAndSettle();
    expect(find.text('120 de 120 músicas'), findsOneWidget);
  });

  testWidgets('álbum: lista numerada, duração total e filtro', (tester) async {
    tester.view.physicalSize = const Size(400, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      wrap(const AlbumScreen(provider: 'spotify', id: 'al1')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Banda · 2020 · 10 músicas · 30 min'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('10'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'faixa 3');
    await tester.pumpAndSettle();
    expect(find.text('Faixa 3'), findsOneWidget);
    expect(find.text('Faixa 4'), findsNothing);
  });

  testWidgets('busca → artista abre dentro da aba, com a navegação', (
    tester,
  ) async {
    await pumpBergastream(
      tester,
      initialLocation: '/buscar',
      size: const Size(400, 1400),
    );
    await tester.enterText(find.byType(TextField), 'queen');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Queen').first);
    await tester.pumpAndSettle();
    expect(find.byType(ArtistScreen), findsOneWidget);
    // Barra de navegação continua lá.
    expect(find.text('Biblioteca'), findsOneWidget);
    await tester.tap(find.text('‹ Voltar'));
    await tester.pumpAndSettle();
    expect(find.byType(ArtistScreen), findsNothing);
  });

  testWidgets('menu ⋮ → "Ir para o álbum"', (tester) async {
    await pumpBergastream(
      tester,
      initialLocation: '/buscar/artista/spotify/banda',
      size: const Size(400, 1400),
    );
    await tester.tap(find.byTooltip('Mais opções').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ir para o álbum'));
    await tester.pumpAndSettle();
    expect(find.byType(AlbumScreen), findsOneWidget);
  });
}
