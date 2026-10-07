import 'package:bergastream/core/storage/key_value_store.dart';
import 'package:bergastream/core/platform/app_platform.dart';
import 'package:bergastream/features/update/app_release.dart';
import 'package:bergastream/features/update/update_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../app_harness.dart';
import '../../fake_update.dart';

Map<String, dynamic> gh(
  String tag, {
  bool draft = false,
  bool prerelease = false,
  List<String> assets = const ['bergastream-android.apk'],
}) => {
  'tag_name': tag,
  'draft': draft,
  'prerelease': prerelease,
  'html_url': 'https://github.com/r/releases/tag/$tag',
  'body': 'notas $tag',
  'assets': [
    for (final a in assets)
      {'name': a, 'browser_download_url': 'https://dl/$a'},
  ],
};

void main() {
  group('AppVersion', () {
    test('lê e compara', () {
      expect(AppVersion.tryParse('1.2.3'), const AppVersion(1, 2, 3));
      expect(AppVersion.tryParse('0.1.0+7'), const AppVersion(0, 1, 0));
      expect(AppVersion.tryParse('2.0'), const AppVersion(2, 0, 0));
      expect(AppVersion.tryParse('v1'), isNull);
      expect(AppVersion.tryParse('1.2.3.4'), isNull);
      expect(const AppVersion(0, 10, 0) > const AppVersion(0, 9, 9), isTrue);
      expect(const AppVersion(1, 0, 0) > const AppVersion(1, 0, 0), isFalse);
    });
  });

  group('AppRelease.latestOf', () {
    test('só tags do Bergastream publicadas; pega a maior versão', () {
      final latest = AppRelease.latestOf([
        gh('jellyfin-v9.0.0'),
        gh('bergastream-v0.3.0', draft: true),
        gh('bergastream-v0.4.0', prerelease: true),
        gh('bergastream-v0.2.0'),
        gh('bergastream-v0.10.0'),
        gh('bergastream-vXYZ'),
      ])!;
      expect(latest.version, const AppVersion(0, 10, 0));
      expect(latest.tag, 'bergastream-v0.10.0');
      expect(latest.notes, 'notas bergastream-v0.10.0');
      expect(
        latest.assets[AppRelease.androidAsset],
        'https://dl/bergastream-android.apk',
      );
    });

    test('nenhuma versão do Bergastream', () {
      expect(AppRelease.latestOf([gh('n8n-v1.0.0')]), isNull);
      expect(AppRelease.latestOf(const []), isNull);
    });
  });

  group('UpdateTarget.of', () {
    test('web e simulação não atualizam', () {
      expect(UpdateTarget.of(const AppPlatform.web()), isNull);
      expect(UpdateTarget.of(const AppPlatform.simulatedAndroid()), isNull);
      // Nos testes o sistema é Android.
      expect(UpdateTarget.of(const AppPlatform.app()), UpdateTarget.android);
    });
  });

  group('UpdateService.check', () {
    late MemoryKeyValueStore store;
    late FakeUpdateRepository repo;

    UpdateService service({UpdateTarget? target = UpdateTarget.android}) {
      final container = ProviderContainer(
        overrides: [
          appPlatformProvider.overrideWithValue(const AppPlatform.app()),
          keyValueStoreProvider.overrideWithValue(store),
          updateRepositoryProvider.overrideWithValue(repo),
          updateTargetProvider.overrideWithValue(target),
        ],
      );
      addTearDown(container.dispose);
      return container.read(updateServiceProvider);
    }

    setUp(() {
      store = MemoryKeyValueStore();
      repo = FakeUpdateRepository(published: release('0.2.0'));
    });

    test('versão nova disponível', () async {
      final result = await service().check();
      expect(result, isA<UpdateAvailable>());
      final available = result! as UpdateAvailable;
      expect(available.current, const AppVersion(0, 1, 0));
      expect(available.release.version, const AppVersion(0, 2, 0));
    });

    test('mesma versão ou mais antiga: em dia', () async {
      repo.published = release('0.1.0');
      expect(await service().check(manual: true), isA<UpToDate>());
      repo.published = null;
      expect(await service().check(manual: true), isA<UpToDate>());
    });

    test('release sem o arquivo desta plataforma não é oferecida', () async {
      repo.published = release(
        '0.2.0',
        assets: {AppRelease.linuxAsset: 'https://dl/l'},
      );
      expect(await service().check(), isA<UpToDate>());
    });

    test('automática: no máximo uma consulta por intervalo', () async {
      final now = DateTime(2026, 10, 7, 12);
      final s = service();
      expect(await s.check(now: now), isA<UpdateAvailable>());
      expect(await s.check(now: now.add(const Duration(hours: 2))), isNull);
      expect(repo.latestCalls, 1);
      expect(
        await s.check(now: now.add(UpdateService.interval)),
        isA<UpdateAvailable>(),
      );
      // A manual não espera o intervalo.
      expect(await s.check(manual: true, now: now), isA<UpdateAvailable>());
    });

    test(
      '"Agora não": a automática não pergunta de novo; a manual sim',
      () async {
        final s = service();
        await s.skip(release('0.2.0'));
        expect(await s.check(), isNull);
        expect(await s.check(manual: true), isA<UpdateAvailable>());
        // Versão ainda mais nova volta a ser oferecida.
        repo.published = release('0.3.0');
        await store.delete(UpdateService.lastCheckKey);
        expect(await s.check(), isA<UpdateAvailable>());
      },
    );

    test('sem rede: falhou (sem quebrar)', () async {
      repo.fail = Exception('sem rede');
      expect(await service().check(manual: true), isA<UpdateCheckFailed>());
    });

    test('plataforma sem atualização: não consulta', () async {
      expect(await service(target: null).check(manual: true), isNull);
      expect(repo.latestCalls, 0);
    });
  });

  group('tela', () {
    Future<void> openWithUpdate(
      WidgetTester tester, {
      required UpdateTarget target,
      required FakeUpdateRepository repo,
      required FakeUpdateLauncher launcher,
      MemoryKeyValueStore? store,
    }) async {
      await pumpBergastream(
        tester,
        updateTarget: target,
        updates: repo,
        launcher: launcher,
        store: store,
      );
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
    }

    testWidgets('Android: ao abrir pergunta; "Baixar e instalar" abre o APK', (
      tester,
    ) async {
      final repo = FakeUpdateRepository(published: release('0.2.0'));
      final launcher = FakeUpdateLauncher();
      await openWithUpdate(
        tester,
        target: UpdateTarget.android,
        repo: repo,
        launcher: launcher,
      );
      expect(
        find.text('Nova versão 0.2.0 disponível (você tem a 0.1.0).'),
        findsOneWidget,
      );
      expect(find.text('Novidades da 0.2.0'), findsOneWidget);

      await tester.tap(find.text('Baixar e instalar'));
      await tester.pumpAndSettle();
      expect(repo.downloads.single, (
        'https://dl/android.apk',
        '/tmp/cache/bergastream-0.2.0-android.apk',
      ));
      expect(launcher.opened, ['/tmp/cache/bergastream-0.2.0-android.apk']);
      expect(find.textContaining('Baixando'), findsNothing);
    });

    testWidgets('Linux: "Baixar" salva em Downloads e abre a pasta', (
      tester,
    ) async {
      final repo = FakeUpdateRepository(published: release('0.2.0'));
      final launcher = FakeUpdateLauncher();
      await openWithUpdate(
        tester,
        target: UpdateTarget.linux,
        repo: repo,
        launcher: launcher,
      );
      expect(find.text('Baixar e instalar'), findsNothing);
      await tester.tap(find.text('Baixar'));
      await tester.pumpAndSettle();
      expect(
        repo.downloads.single.$2,
        '/home/u/Downloads/bergastream-0.2.0-linux-x64.tar.gz',
      );
      expect(launcher.opened, ['/home/u/Downloads']);
      expect(find.text('Atualização salva em Downloads'), findsOneWidget);
    });

    testWidgets('"Ver no GitHub" abre a página da versão', (tester) async {
      final launcher = FakeUpdateLauncher();
      await openWithUpdate(
        tester,
        target: UpdateTarget.windows,
        repo: FakeUpdateRepository(published: release('0.2.0')),
        launcher: launcher,
      );
      await tester.tap(find.text('Ver no GitHub'));
      await tester.pumpAndSettle();
      expect(launcher.pages, [
        'https://github.com/x/releases/tag/bergastream-v0.2.0',
      ]);
    });

    testWidgets('"Agora não" guarda a versão recusada', (tester) async {
      final store = MemoryKeyValueStore();
      await openWithUpdate(
        tester,
        target: UpdateTarget.android,
        repo: FakeUpdateRepository(published: release('0.2.0')),
        launcher: FakeUpdateLauncher(),
        store: store,
      );
      await tester.tap(find.text('Agora não'));
      await tester.pumpAndSettle();
      expect(await store.read(UpdateService.skippedKey), '0.2.0');
    });

    testWidgets('Ajustes: versão e "Verificar atualizações"', (tester) async {
      final repo = FakeUpdateRepository(published: release('0.1.0'));
      await pumpBergastream(
        tester,
        updateTarget: UpdateTarget.android,
        updates: repo,
        launcher: FakeUpdateLauncher(),
      );
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ajustes').last);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Verificar atualizações'), 200);
      expect(find.text('Bergastream 0.1.0'), findsOneWidget);
      await tester.tap(find.text('Verificar atualizações'));
      await tester.pumpAndSettle();
      expect(
        find.text('Você já tem a versão mais recente (0.1.0)'),
        findsOneWidget,
      );
    });

    testWidgets('sem plataforma de atualização, Ajustes não mostra "Sobre"', (
      tester,
    ) async {
      await pumpBergastream(tester);
      await tester.tap(find.text('Ajustes').last);
      await tester.pumpAndSettle();
      expect(find.text('Verificar atualizações'), findsNothing);
      expect(find.byIcon(Icons.system_update), findsNothing);
    });
  });
}
