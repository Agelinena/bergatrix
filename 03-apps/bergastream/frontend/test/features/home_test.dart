import 'dart:convert';

import 'package:bergastream/core/storage/key_value_store.dart';
import 'package:bergastream/data/local/database.dart';
import 'package:bergastream/data/repositories/history_repository.dart';
import 'package:bergastream/features/auth/session.dart';
import 'package:bergastream/features/home/greeting.dart';
import 'package:bergastream/features/home/home_providers.dart';
import 'package:bergastream/features/player/player_controller.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../app_harness.dart';
import '../fake_player.dart';

void main() {
  DateTime at(int hour) => DateTime(2026, 10, 6, hour);

  test('saudação por horário', () {
    expect(greetingFor(at(5)), 'Bom dia');
    expect(greetingFor(at(11)), 'Bom dia');
    expect(greetingFor(at(12)), 'Boa tarde');
    expect(greetingFor(at(17)), 'Boa tarde');
    expect(greetingFor(at(18)), 'Boa noite');
    expect(greetingFor(at(0)), 'Boa noite');
    expect(greetingFor(at(4)), 'Boa noite');
  });

  test('horas ouvidas', () {
    expect(formatListening(42 * 3600 + 1200), '42 h');
    expect(formatListening(41 * 3600 + 2000), '42 h');
    expect(formatListening(35 * 60), '35 min');
    expect(formatListening(0), '0 min');
  });

  test('id da reprodução é um UUID v4 único', () {
    final a = PlayRecord.newClientId();
    expect(
      a,
      matches(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ),
      ),
    );
    expect(PlayRecord.newClientId(), isNot(a));
  });

  testWidgets('Início com métricas reais do histórico', (tester) async {
    await pumpBergastream(tester, size: const Size(400, 1600));
    expect(find.text('42 h'), findsOneWidget);
    expect(find.text('318'), findsOneWidget);
    expect(find.text('Artistas que você mais ouve'), findsOneWidget);
    expect(find.text('Mais tocadas'), findsOneWidget);
    expect(find.text('Bohemian Rhapsody'), findsOneWidget);
  });

  testWidgets('sem servidor mostra a última resposta guardada', (tester) async {
    final store = MemoryKeyValueStore();
    final container = await pumpBergastream(
      tester,
      store: store,
      size: const Size(400, 1600),
    );
    expect(store.values['home.stats'], isNotNull);
    container.read(sessionProvider.notifier).setServerAvailable(false);
    await settleDb(tester);
    expect(find.text('42 h'), findsOneWidget);
  });

  testWidgets('sem servidor e sem cache: estado vazio', (tester) async {
    await pumpBergastream(
      tester,
      session: noServer.copyWith(localMode: true),
      size: const Size(400, 1000),
    );
    expect(
      find.text('Entre ou baixe músicas para ver suas métricas aqui.'),
      findsOneWidget,
    );
  });

  testWidgets('tocar 30 s registra no servidor; falhando, fica pendente', (
    tester,
  ) async {
    final history = FakeHistoryRepository();
    final engine = FakeAudioEngine();
    final db = AppDatabase(NativeDatabase.memory());
    final container = await pumpBergastream(
      tester,
      history: history,
      engine: engine,
      db: db,
      initialLocation: '/buscar',
      size: const Size(400, 1400),
    );
    await tester.enterText(find.byType(TextField), 'queen');
    await tester.pump(const Duration(milliseconds: 400));
    await settleDb(tester);
    await tester.tap(find.text('Bohemian Rhapsody'));
    await settleDb(tester);
    engine.emitPosition(const Duration(seconds: 31));
    await settleDb(tester);
    expect(history.sent.single.track.title, 'Bohemian Rhapsody');

    // Servidor falhando: vai para o banco local, para enviar depois.
    history.failing = true;
    await container
        .read(playerProvider.notifier)
        .playList([song('Outra')], 0, context: 'Busca');
    await settleDb(tester);
    engine.emitPosition(const Duration(seconds: 40));
    await settleDb(tester);
    final pending = await db.pendingPlaysInOrder();
    expect(pending, hasLength(1));
    expect(jsonDecode(pending.single.trackJson)['client_id'], isNotEmpty);
  });
}
