import 'package:bergastream/core/network/api_error.dart';
import 'package:bergastream/core/platform/app_platform.dart';
import 'package:bergastream/data/models/search_full.dart';
import 'package:bergastream/data/repositories/playlist_repository.dart';
import 'package:bergastream/data/repositories/search_repository.dart';
import 'package:bergastream/features/player/player_controller.dart';
import 'package:bergastream/features/search/imported_link_screen.dart';
import 'package:bergastream/features/search/search_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../app_harness.dart';
import '../helpers.dart';

void main() {
  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.pump(SearchScreen.debounce);
    await tester.pumpAndSettle();
  }

  void tall(WidgetTester tester) {
    tester.view.physicalSize = const Size(400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('sem histórico mostra só a dica de colar link', (tester) async {
    await tester.pumpWidget(wrap(const SearchScreen()));
    expect(find.text('Buscas recentes'), findsNothing);
    expect(
      find.textContaining('Cole um link do Spotify, Deezer ou YouTube'),
      findsOneWidget,
    );
  });

  testWidgets('resultados em Artistas, Álbuns e Músicas', (tester) async {
    tall(tester);
    await tester.pumpWidget(wrap(const SearchScreen()));
    await type(tester, 'daft');
    expect(find.text('Artistas'), findsOneWidget);
    expect(find.text('Álbuns'), findsOneWidget);
    expect(find.text('Músicas'), findsOneWidget);
    expect(find.text('Get Lucky'), findsOneWidget);
    expect(find.text('Random Access Memories'), findsOneWidget);
  });

  testWidgets('confirmar a busca guarda no histórico e tocar repete', (
    tester,
  ) async {
    tall(tester);
    final repo = FakeSearchRepository();
    await tester.pumpWidget(wrap(const SearchScreen(), search: repo));
    await tester.enterText(find.byType(TextField), 'queen');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    expect(find.text('Buscas recentes'), findsOneWidget);
    await tester.tap(find.text('queen'));
    await tester.pumpAndSettle();
    expect(find.text('Bohemian Rhapsody'), findsOneWidget);
  });

  testWidgets('nada encontrado', (tester) async {
    await tester.pumpWidget(wrap(const SearchScreen()));
    await type(tester, 'xyz');
    expect(
      find.text(
        'Nada encontrado para "xyz". Tente outro nome ou cole um link.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('digitação rápida faz uma única busca (espera de 400 ms)', (
    tester,
  ) async {
    final repo = FakeSearchRepository();
    await tester.pumpWidget(wrap(const SearchScreen(), search: repo));
    for (final text in ['q', 'qu', 'que', 'quee', 'queen']) {
      await tester.enterText(find.byType(TextField), text);
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(repo.calls, 0);
    await tester.pump(SearchScreen.debounce);
    await tester.pumpAndSettle();
    expect(repo.calls, 1);
  });

  testWidgets('erro do servidor mostra a mensagem e "Tentar de novo"', (
    tester,
  ) async {
    final repo = _FailingSearch();
    await tester.pumpWidget(wrap(const SearchScreen(), search: repo));
    await type(tester, 'queen');
    expect(
      find.text('O servidor teve um problema. Tente de novo em instantes.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Tentar de novo'));
    await tester.pumpAndSettle();
    expect(repo.calls, 2);
  });

  testWidgets('trocar a origem refaz a busca com a origem nova', (
    tester,
  ) async {
    final repo = FakeSearchRepository();
    await tester.pumpWidget(wrap(const SearchScreen(), search: repo));
    await type(tester, 'queen');
    await tester.tap(find.text('YT Music'));
    await tester.pumpAndSettle();
    expect(repo.calls, 2);
  });

  testWidgets('link de música mostra a faixa exata, sem os chips', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(const SearchScreen()));
    await type(tester, 'https://open.spotify.com/track/abc');
    expect(find.text('Música'), findsOneWidget);
    expect(find.text('Bohemian Rhapsody'), findsOneWidget);
    expect(find.text('Spotify'), findsNothing);
  });

  testWidgets('link que não abre mostra o aviso', (tester) async {
    await tester.pumpWidget(wrap(const SearchScreen()));
    await type(tester, 'https://open.spotify.com/playlist/naoabre');
    expect(
      find.text('Não foi possível abrir este link. Ele pode ser privado.'),
      findsOneWidget,
    );
  });

  testWidgets('link de playlist: cartão e "Importar" → "Só as músicas"', (
    tester,
  ) async {
    final playlists = FakePlaylistRepository();
    await tester.pumpWidget(wrap(const SearchScreen(), playlists: playlists));
    await type(tester, 'https://www.deezer.com/playlist/1');
    expect(find.text('Roadtrip importada'), findsOneWidget);
    expect(find.text('3 músicas · Deezer'), findsOneWidget);

    await tester.tap(find.text('Importar'));
    await tester.pumpAndSettle();
    expect(find.text('Importar "Roadtrip importada"?'), findsOneWidget);
    await tester.tap(find.text('Só as músicas'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Roadtrip'));
    await tester.pumpAndSettle();
    expect(playlists.added['p1'], hasLength(3));
    expect(find.text('3 músicas adicionadas a Roadtrip'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  });

  testWidgets('"Nova playlist" sugere o nome do link e cria', (tester) async {
    final playlists = FakePlaylistRepository();
    await tester.pumpWidget(wrap(const SearchScreen(), playlists: playlists));
    await type(tester, 'https://open.spotify.com/playlist/1');
    await tester.tap(find.text('Importar'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Só as músicas'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nova playlist'));
    await tester.pumpAndSettle();
    expect(
      find.widgetWithText(TextField, 'Roadtrip importada'),
      findsOneWidget,
    );
    await tester.tap(find.text('Criar'));
    await tester.pumpAndSettle();
    expect(playlists.playlists.last.name, 'Roadtrip importada');
    expect(playlists.added[playlists.playlists.last.id], hasLength(3));
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  });

  testWidgets('"Importar tudo": nome, descrição e todas as músicas', (
    tester,
  ) async {
    final playlists = FakePlaylistRepository();
    await pumpBergastream(
      tester,
      initialLocation: '/buscar',
      playlists: playlists,
      size: const Size(400, 1400),
    );
    await type(tester, 'https://open.spotify.com/playlist/1');
    await tester.tap(find.text('Importar'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Importar tudo'));
    await settleDb(tester);
    final created = playlists.playlists.last;
    expect(created.name, 'Roadtrip importada');
    expect(playlists.descriptions[created.id], 'Para pegar a estrada');
    expect(playlists.covers, isEmpty); // o link do teste não tem capa
    expect(playlists.added[created.id], hasLength(3));
    // Abre a playlist nova, com a descrição.
    expect(find.text('Para pegar a estrada'), findsOneWidget);
    expect(
      find.text('Playlist "Roadtrip importada" importada com 3 músicas'),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  testWidgets('busca mostra playlists e abre como link importado', (
    tester,
  ) async {
    await pumpBergastream(
      tester,
      initialLocation: '/buscar',
      size: const Size(400, 1600),
    );
    await type(tester, 'rock');
    expect(find.text('Playlists'), findsOneWidget);
    expect(find.text('Rock Brasil Anos 80'), findsOneWidget);
    expect(find.text('Deezer · 40 músicas'), findsOneWidget);

    await tester.tap(find.text('Rock Brasil Anos 80'));
    await tester.pumpAndSettle();
    expect(find.byType(ImportedLinkScreen), findsOneWidget);
    expect(find.text('Importar'), findsOneWidget);
  });

  testWidgets('"rádio <artista>" traz a rádio antes de tudo', (tester) async {
    await pumpBergastream(
      tester,
      initialLocation: '/buscar',
      size: const Size(400, 1600),
    );
    await type(tester, 'rádio queen');
    expect(find.text('Rádio Scorpions'), findsOneWidget);
    expect(find.text('Rádio · YouTube Music'), findsOneWidget);
    final playlists = tester.getTopLeft(find.text('Playlists')).dy;
    for (final other in ['Músicas', 'Artistas']) {
      final f = find.text(other);
      if (f.evaluate().isNotEmpty) {
        expect(playlists < tester.getTopLeft(f.first).dy, isTrue);
      }
    }
  });

  testWidgets('busca sem playlists não mostra a seção', (tester) async {
    await pumpBergastream(
      tester,
      initialLocation: '/buscar',
      size: const Size(400, 1600),
    );
    await type(tester, 'queen');
    expect(find.text('Playlists'), findsNothing);
  });

  testWidgets('arrastar a linha para o lado adiciona à fila', (tester) async {
    tall(tester);
    final container = await pumpBergastream(
      tester,
      initialLocation: '/buscar',
      size: const Size(400, 1400),
    );
    await type(tester, 'queen');
    await tester.drag(find.text('Bohemian Rhapsody'), const Offset(-300, 0));
    await tester.pumpAndSettle();
    expect(find.text('Na fila: toca depois da atual'), findsOneWidget);
    // Nada tocava: a faixa da fila começa a tocar.
    expect(
      container.read(playerProvider).current!.track.title,
      'Bohemian Rhapsody',
    );
    expect(find.text('Bohemian Rhapsody'), findsWidgets);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  });

  testWidgets('menu ⋮: compartilhar pergunta o tipo de link e copia (web)', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    await tester.pumpWidget(
      wrap(const SearchScreen(), platform: const AppPlatform.web()),
    );
    await type(tester, 'https://open.spotify.com/track/abc');
    await tester.tap(find.byTooltip('Mais opções'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Compartilhar'));
    await tester.pumpAndSettle();
    expect(find.text('Link do Spotify'), findsOneWidget);
    await tester.tap(find.text('Link do app'));
    await tester.pumpAndSettle();
    expect(copied, contains('/#/buscar?link=https%3A%2F%2Fopen.spotify.com'));
    expect(find.text('Link copiado'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  });

  testWidgets('menu ⋮: "Adicionar à playlist"', (tester) async {
    final playlists = FakePlaylistRepository();
    await tester.pumpWidget(wrap(const SearchScreen(), playlists: playlists));
    await type(tester, 'https://open.spotify.com/track/abc');
    await tester.tap(find.byTooltip('Mais opções'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Adicionar à playlist'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Roadtrip'));
    await tester.pumpAndSettle();
    expect(playlists.added['p1'], ['Bohemian Rhapsody']);
    expect(find.text('Adicionada a Roadtrip'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  });

  testWidgets('cartão do link abre a playlist importada', (tester) async {
    await pumpBergastream(
      tester,
      initialLocation: '/buscar',
      size: const Size(400, 1400),
    );
    await type(tester, 'https://open.spotify.com/playlist/1');
    await tester.tap(find.text('Roadtrip importada'));
    await tester.pumpAndSettle();
    expect(find.byType(ImportedLinkScreen), findsOneWidget);
    expect(find.text('Blinding Lights'), findsOneWidget);
    expect(find.textContaining('3 músicas'), findsOneWidget);
  });

  testWidgets('"Link do app" abre a Busca com o link resolvido', (
    tester,
  ) async {
    await pumpBergastream(
      tester,
      initialLocation:
          '/buscar?link=${Uri.encodeQueryComponent('https://open.spotify.com/track/abc')}',
    );
    await tester.pumpAndSettle();
    expect(find.text('Bohemian Rhapsody'), findsOneWidget);
  });
}

class _FailingSearch implements SearchRepository {
  int calls = 0;

  @override
  Future<FullSearchResult> search(String query, SearchSource source) async {
    calls++;
    throw const ApiException(ApiErrorKind.servidor);
  }

  @override
  Future<ResolvedLink> resolve(String url) async =>
      throw const ApiException(ApiErrorKind.servidor);

  @override
  Future<List<PlaylistResult>> searchPlaylists(String query) async =>
      throw const ApiException(ApiErrorKind.servidor);
}
