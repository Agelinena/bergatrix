import 'package:bergastream/data/models/playlist_models.dart';
import 'package:bergastream/data/models/playlist_op.dart';
import 'package:bergastream/data/repositories/playlist_repository.dart';
import 'package:bergastream/features/library/library_providers.dart';
import 'package:bergastream/features/library/people_screen.dart';
import 'package:bergastream/features/library/playlist_screen.dart';
import 'package:bergastream/features/player/player_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../app_harness.dart';

void main() {
  final tracks = FakePlaylistRepository().tracks;

  group('ordenação e busca', () {
    List<String> titles(List<PlaylistTrack> l) => [for (final t in l) t.title];

    test('ordem da playlist segue a posição', () {
      expect(
        titles(
          sortAndFilter(tracks.reversed.toList(), PlaylistSort.playlist, ''),
        ).first,
        'Blinding Lights',
      );
    });

    test('adicionadas por último / primeiro (data de adição)', () {
      expect(titles(sortAndFilter(tracks, PlaylistSort.recentes, '')), [
        'Smells Like Teen Spirit',
        'Redbone',
        'Get Lucky',
        'Levitating',
        'Blinding Lights',
      ]);
      expect(
        titles(sortAndFilter(tracks, PlaylistSort.antigas, '')).first,
        'Blinding Lights',
      );
    });

    test('título A–Z e Z–A', () {
      final az = titles(sortAndFilter(tracks, PlaylistSort.tituloAz, ''));
      expect(az, [
        'Blinding Lights',
        'Get Lucky',
        'Levitating',
        'Redbone',
        'Smells Like Teen Spirit',
      ]);
      expect(
        titles(sortAndFilter(tracks, PlaylistSort.tituloZa, '')),
        az.reversed,
      );
    });

    test('artista (depois título), nos dois sentidos', () {
      expect(
        titles(sortAndFilter(tracks, PlaylistSort.artistaAz, '')).first,
        'Redbone',
      );
      expect(
        titles(sortAndFilter(tracks, PlaylistSort.artistaZa, '')).first,
        'Blinding Lights',
      );
    });

    test('duração: mais curtas e mais longas', () {
      expect(
        titles(sortAndFilter(tracks, PlaylistSort.curtas, '')).first,
        'Blinding Lights',
      );
      expect(
        titles(sortAndFilter(tracks, PlaylistSort.longas, '')).first,
        'Get Lucky',
      );
    });

    test('busca por título ou artista', () {
      expect(titles(sortAndFilter(tracks, PlaylistSort.playlist, 'daft')), [
        'Get Lucky',
      ]);
      expect(sortAndFilter(tracks, PlaylistSort.playlist, 'xyz'), isEmpty);
    });

    test('legenda da lista', () {
      expect(playlistSubtitle(tracks: 5, people: 3), '5 músicas · 3 pessoas');
      expect(playlistSubtitle(tracks: 1, people: 1), '1 música · só você');
    });
  });

  Future<FakePlaylistRepository> openDetail(
    WidgetTester tester, {
    PlaylistRole role = PlaylistRole.owner,
  }) async {
    final repo = FakePlaylistRepository(role: role);
    await pumpBergastream(
      tester,
      initialLocation: '/biblioteca',
      playlists: repo,
      size: const Size(400, 1400),
    );
    await tester.tap(find.text('Roadtrip'));
    await tester.pumpAndSettle();
    expect(find.byType(PlaylistScreen), findsOneWidget);
    return repo;
  }

  testWidgets('lista e detalhe: duração, colaboradores e "por Fulano"', (
    tester,
  ) async {
    await openDetail(tester);
    expect(
      find.text('5 músicas · 23 min · colaboram: Você, Ana, Pedro'),
      findsOneWidget,
    );
    expect(find.text('Dua Lipa · por Ana'), findsOneWidget);
    expect(find.text('The Weeknd · por Você'), findsOneWidget);
  });

  testWidgets('ordenar e buscar dentro da playlist', (tester) async {
    await openDetail(tester);
    double y(String t) => tester.getTopLeft(find.text(t)).dy;
    expect(y('Blinding Lights') < y('Levitating'), isTrue);
    await tester.tap(find.text('Ordem'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Adicionadas por último'));
    await tester.pumpAndSettle();
    expect(find.text('Recentes'), findsOneWidget);
    expect(y('Smells Like Teen Spirit') < y('Blinding Lights'), isTrue);
    await tester.tap(find.text('Recentes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Título (A–Z)'));
    await tester.pumpAndSettle();
    expect(y('Get Lucky') < y('Levitating'), isTrue);
    await tester.enterText(find.byType(TextField), 'nirvana');
    await tester.pumpAndSettle();
    expect(find.text('Smells Like Teen Spirit'), findsOneWidget);
    expect(find.text('Get Lucky'), findsNothing);
  });

  testWidgets('play toca na ordem; com Aleatório, embaralhado', (tester) async {
    final container = await pumpBergastream(
      tester,
      initialLocation: '/biblioteca/playlist/p1',
      size: const Size(400, 1400),
    );
    await tester.tap(find.byIcon(Icons.play_arrow).first);
    await tester.pumpAndSettle();
    var s = container.read(playerProvider);
    expect(s.current!.track.title, 'Blinding Lights');
    expect(s.shuffle, isFalse);
    expect(s.upNext.first.track.title, 'Levitating');
    expect(s.context, 'Roadtrip');

    await tester.tap(find.text('Aleatório'));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.play_arrow).first);
    await tester.pumpAndSettle();
    s = container.read(playerProvider);
    expect(s.shuffle, isTrue);
  });

  testWidgets('quem só vê não tem opções de edição', (tester) async {
    await openDetail(tester, role: PlaylistRole.viewer);
    await tester.tap(find.byTooltip('Opções da playlist'));
    await tester.pumpAndSettle();
    expect(find.text('Renomear'), findsNothing);
    expect(find.text('Apagar playlist'), findsNothing);
    expect(find.text('Pessoas'), findsNothing);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Mais opções').first);
    await tester.pumpAndSettle();
    expect(find.text('Remover desta playlist'), findsNothing);
  });

  testWidgets('dono remove faixa e reordena', (tester) async {
    final repo = await openDetail(tester);
    await tester.tap(find.byTooltip('Mais opções').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remover desta playlist'));
    await tester.pumpAndSettle();
    expect(repo.removed, ['tr0']);
    expect(find.text('Blinding Lights'), findsNothing);

    await tester.tap(find.byTooltip('Opções da playlist'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reordenar'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.drag_handle), findsNWidgets(4));
    await tester.tap(find.text('Concluir'));
    await tester.pumpAndSettle();
    // Nada mudou de lugar: nada vai para o servidor.
    expect(repo.reorders, isEmpty);
    expect(
      repo.batches.expand((b) => b).where((o) => o.type == PlaylistOpType.move),
      isEmpty,
    );
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  });

  testWidgets('Pessoas: dono define quem vê e quem edita', (tester) async {
    final repo = await openDetail(tester);
    await tester.tap(find.byTooltip('Opções da playlist'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pessoas'));
    await tester.pumpAndSettle();
    expect(find.byType(PeopleScreen), findsOneWidget);
    // Dono (Demo) não aparece; Ana e Pedro sim.
    expect(find.text('Demo'), findsNothing);
    await tester.tap(find.text('Edita').last);
    await tester.pumpAndSettle();
    expect(repo.members['p1']!['u3'], PlaylistRole.editor);
  });

  testWidgets('nova playlist no servidor abre o detalhe', (tester) async {
    final repo = FakePlaylistRepository();
    await pumpBergastream(
      tester,
      initialLocation: '/biblioteca',
      playlists: repo,
      size: const Size(400, 1000),
    );
    await tester.tap(find.text('Nova playlist'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Foco');
    await tester.tap(find.text('Criar'));
    await tester.pumpAndSettle();
    expect(repo.playlists.last.name, 'Foco');
    expect(find.byType(PlaylistScreen), findsOneWidget);
  });

  testWidgets('sem login: playlist local "Só neste aparelho"', (tester) async {
    await pumpBergastream(
      tester,
      session: noServer.copyWith(localMode: true),
      initialLocation: '/biblioteca',
      size: const Size(400, 1000),
    );
    await tester.tap(find.text('Nova playlist'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Viagem');
    await tester.tap(find.text('Criar'));
    await tester.pumpAndSettle();
    expect(find.text('0 músicas · Só neste aparelho'), findsOneWidget);
    await tester.tap(find.text('‹ Biblioteca'));
    await tester.pumpAndSettle();
    expect(find.text('Viagem'), findsOneWidget);
    expect(find.text('Só neste aparelho'), findsOneWidget);
  });
}
