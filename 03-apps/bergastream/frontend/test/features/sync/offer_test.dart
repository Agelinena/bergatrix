import 'package:bergastream/core/storage/key_value_store.dart';
import 'package:bergastream/data/repositories/playlist_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../app_harness.dart';

void main() {
  testWidgets('ao entrar com playlists locais, oferece enviar ao servidor', (
    tester,
  ) async {
    final store = MemoryKeyValueStore({
      'local_playlists': '[{"id":"local-1","name":"Viagem","track_ids":[]}]',
    });
    final playlists = FakePlaylistRepository();
    await pumpBergastream(
      tester,
      store: store,
      playlists: playlists,
      session: noServer.copyWith(localMode: true),
      initialLocation: '/entrar',
      size: const Size(400, 1000),
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'https://musica.meuservidor.com'),
      'musica.com',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Seu usuário'),
      'demo',
    );
    await tester.enterText(find.widgetWithText(TextField, 'Sua senha'), 'demo');
    await tester.tap(find.text('Entrar'));
    await settleDb(tester);
    await tester.pump(const Duration(milliseconds: 500));
    await settleDb(tester);
    expect(
      find.text('Enviar suas playlists locais para o servidor?'),
      findsOneWidget,
    );
    await tester.tap(find.text('Enviar'));
    await settleDb(tester);
    expect(playlists.playlists.map((p) => p.name), contains('Viagem'));
    expect(store.values['local_playlists'], '[]');
    await tester.pump(const Duration(seconds: 2));
    await settleDb(tester);
  });

  testWidgets('"Manter só aqui" não envia', (tester) async {
    final store = MemoryKeyValueStore({
      'local_playlists': '[{"id":"local-1","name":"Viagem","track_ids":[]}]',
    });
    final playlists = FakePlaylistRepository();
    await pumpBergastream(
      tester,
      store: store,
      playlists: playlists,
      session: noServer.copyWith(localMode: true),
      initialLocation: '/entrar',
      size: const Size(400, 1000),
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'https://musica.meuservidor.com'),
      'musica.com',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Seu usuário'),
      'demo',
    );
    await tester.enterText(find.widgetWithText(TextField, 'Sua senha'), 'demo');
    await tester.tap(find.text('Entrar'));
    await settleDb(tester);
    await tester.pump(const Duration(milliseconds: 500));
    await settleDb(tester);
    await tester.tap(find.text('Manter só aqui'));
    await settleDb(tester);
    expect(playlists.playlists.map((p) => p.name), isNot(contains('Viagem')));
  });
}
