import 'package:bergastream/core/network/api_client.dart';
import 'package:bergastream/core/network/api_error.dart';
import 'package:bergastream/data/models/auth.dart';
import 'package:bergastream/data/repositories/http_auth_repository.dart';
import 'package:bergastream/data/repositories/playback_repository.dart';
import 'package:bergastream/data/repositories/search_repository.dart';
import 'package:bergastream/data/repositories/server_status_repository.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fake_http.dart';

void main() {
  group('HttpAuthRepository', () {
    late ProviderContainer container;
    setUp(() {
      container = ProviderContainer();
      addTearDown(container.dispose);
    });

    HttpAuthRepository repoWith(FakeAdapter adapter) {
      final dio = createDio()..httpClientAdapter = adapter;
      return HttpAuthRepository(_RefHolder.of(container), dio);
    }

    Future<AuthError?> loginError(FakeAdapter adapter) async {
      try {
        await repoWith(
          adapter,
        ).login(server: 'https://s.com', username: 'lucas', password: 'x');
        return null;
      } on AuthException catch (e) {
        return e.error;
      }
    }

    Future<AuthError?> refreshError(FakeAdapter adapter) async {
      try {
        await repoWith(
          adapter,
        ).refresh(server: 'https://s.com', refreshToken: 'r');
        return null;
      } on AuthException catch (e) {
        return e.error;
      }
    }

    test('renovação: só a API recusando encerra a sessão', () async {
      expect(
        await refreshError(
          FakeAdapter((_) async => jsonBody({'detail': 'x'}, status: 401)),
        ),
        AuthError.credenciaisInvalidas,
      );
      // Proxy na frente (contêiner reiniciando, Authentik): servidor fora.
      for (final status in [403, 404, 429, 502]) {
        expect(
          await refreshError(
            FakeAdapter(
              (_) async => ResponseBody.fromString(
                '<html>erro</html>',
                status,
                headers: {
                  Headers.contentTypeHeader: ['text/html'],
                },
              ),
            ),
          ),
          AuthError.semConexao,
          reason: 'HTTP $status do proxy',
        );
      }
    });

    test('login lê a resposta real do backend', () async {
      final adapter = FakeAdapter((_) async => jsonBody(fixture('login.json')));
      final response = await repoWith(
        adapter,
      ).login(server: 'https://s.com', username: 'lucas', password: 'segredo');
      expect(response.user.username, 'lucas');
      expect(response.refreshToken, 'refresh-1');
      expect(
        adapter.requests.single.uri.toString(),
        'https://s.com/api/auth/login',
      );
      expect(adapter.requests.single.data, {
        'username': 'lucas',
        'password': 'segredo',
      });
    });

    test('mapeia os erros do login', () async {
      expect(
        await loginError(
          FakeAdapter((_) async => jsonBody({'detail': 'x'}, status: 401)),
        ),
        AuthError.credenciaisInvalidas,
      );
      expect(
        await loginError(
          FakeAdapter((_) async => jsonBody({'detail': []}, status: 422)),
        ),
        AuthError.credenciaisInvalidas,
      );
      expect(
        await loginError(
          FakeAdapter((_) async => jsonBody({'detail': 'x'}, status: 429)),
        ),
        AuthError.muitasTentativas,
      );
      expect(
        await loginError(
          FakeAdapter((_) async => jsonBody('nada', status: 404)),
        ),
        AuthError.servidorNaoEncontrado,
      );
      expect(
        await loginError(
          FakeAdapter(
            (o) async => throw DioException.connectionError(
              requestOptions: o,
              reason: 'Failed host lookup: naoexiste.com',
            ),
          ),
        ),
        AuthError.servidorNaoEncontrado,
      );
      expect(
        await loginError(
          FakeAdapter(
            (o) async => throw DioException.connectionError(
              requestOptions: o,
              reason: 'Connection refused',
            ),
          ),
        ),
        AuthError.semConexao,
      );
      // Respondeu 200 mas não é um servidor Bergastream.
      expect(
        await loginError(FakeAdapter((_) async => jsonBody({'ola': 1}))),
        AuthError.servidorNaoEncontrado,
      );
    });

    test('config de cadastro', () async {
      final repo = repoWith(
        FakeAdapter((_) async => jsonBody({'registration_enabled': true})),
      );
      expect((await repo.options('https://s.com')).registrationEnabled, isTrue);
      final offline = repoWith(
        FakeAdapter(
          (o) async => throw DioException.connectionError(
            requestOptions: o,
            reason: 'x',
          ),
        ),
      );
      expect(
        (await offline.options('https://s.com')).registrationEnabled,
        isFalse,
      );
    });

    test('opções de login e troca do código do Authentik', () async {
      final adapter = FakeAdapter(
        (o) async => o.path.endsWith('/config')
            ? jsonBody({
                'registration_enabled': false,
                'oidc_enabled': true,
                'password_login_enabled': false,
              })
            : o.data['code'] == 'bom'
            ? jsonBody(fixture('login.json'))
            : jsonBody({'detail': 'Código inválido'}, status: 401),
      );
      final repo = repoWith(adapter);
      final options = await repo.options('https://s.com');
      expect(options.oidcEnabled, isTrue);
      expect(options.passwordLoginEnabled, isFalse);
      final tokens = await repo.exchangeOidc(
        server: 'https://s.com',
        code: 'bom',
        verifier: 'v' * 43,
      );
      expect(tokens.user.username, 'lucas');
      expect(adapter.requests.last.uri.path, '/api/auth/oidc/exchange');
      await expectLater(
        repo.exchangeOidc(server: 'https://s.com', code: 'x', verifier: 'v'),
        throwsA(
          isA<AuthException>().having(
            (e) => e.error,
            'error',
            AuthError.authentikFalhou,
          ),
        ),
      );
    });

    test('senha desligada no servidor: "use o Authentik"', () async {
      final repo = repoWith(
        FakeAdapter(
          (_) async =>
              jsonBody({'detail': 'Entre pelo Authentik'}, status: 403),
        ),
      );
      await expectLater(
        repo.login(server: 'https://s.com', username: 'a', password: 'b'),
        throwsA(
          isA<AuthException>().having(
            (e) => e.error,
            'error',
            AuthError.useAuthentik,
          ),
        ),
      );
    });

    group('descoberta do endereço (Traefik modelo B)', () {
      const config = {'registration_enabled': false};

      test('usa o endereço simples quando ele responde', () async {
        final adapter = FakeAdapter((_) async => jsonBody(config));
        final found = await repoWith(adapter).discoverServer('https://b.com');
        expect(found, 'https://b.com');
        expect(
          adapter.requests.single.uri.toString(),
          'https://b.com/api/auth/config',
        );
      });

      test('cai no bypass se o simples não for o Bergastream', () async {
        final adapter = FakeAdapter(
          (o) async => o.uri.path.startsWith('/api-access-bypass')
              ? jsonBody(config)
              : jsonBody({'detail': 'Not Found'}, status: 404),
        );
        expect(
          await repoWith(adapter).discoverServer('https://b.com'),
          'https://b.com/api-access-bypass',
        );
      });

      test('sem Traefik cai no endereço digitado', () async {
        final adapter = FakeAdapter(
          (o) async => o.uri.path.startsWith('/api-access-bypass')
              ? jsonBody({'detail': 'Not Found'}, status: 404)
              : jsonBody(config),
        );
        expect(
          await repoWith(adapter).discoverServer('http://192.168.1.5:8080'),
          'http://192.168.1.5:8080',
        );
      });

      test('página do Authentik (HTML) não conta como servidor', () async {
        final adapter = FakeAdapter(
          (o) async => o.uri.path.startsWith('/api-access-bypass')
              ? jsonBody(config)
              : ResponseBody.fromString(
                  '<html>login</html>',
                  200,
                  headers: {
                    Headers.contentTypeHeader: ['text/html'],
                  },
                ),
        );
        expect(
          await repoWith(adapter).discoverServer('https://b.com'),
          'https://b.com/api-access-bypass',
        );
        final onlyHtml = FakeAdapter(
          (_) async => ResponseBody.fromString(
            '<html>login</html>',
            200,
            headers: {
              Headers.contentTypeHeader: ['text/html'],
            },
          ),
        );
        await expectLater(
          repoWith(onlyHtml).discoverServer('https://b.com'),
          throwsA(
            isA<AuthException>().having(
              (e) => e.error,
              'error',
              AuthError.servidorNaoEncontrado,
            ),
          ),
        );
      });

      test('endereço com caminho é usado como está', () async {
        final adapter = FakeAdapter((_) async => jsonBody(config));
        expect(
          await repoWith(
            adapter,
          ).discoverServer('https://b.com/api-access-bypass'),
          'https://b.com/api-access-bypass',
        );
        expect(adapter.requests, hasLength(1));
      });

      test('sem rede: erro de conexão', () async {
        final adapter = FakeAdapter(
          (o) async => throw DioException.connectionError(
            requestOptions: o,
            reason: 'x',
          ),
        );
        await expectLater(
          repoWith(adapter).discoverServer('https://b.com'),
          throwsA(
            isA<AuthException>().having(
              (e) => e.error,
              'error',
              AuthError.semConexao,
            ),
          ),
        );
      });
    });
  });

  group('HttpSearchRepository', () {
    SearchRepository repoWith(FakeAdapter adapter) => HttpSearchRepository(
      createDio(baseUrl: 'https://s.com')..httpClientAdapter = adapter,
    );

    test('busca completa: resposta real do YT Music', () async {
      final adapter = FakeAdapter(
        (_) async => jsonBody(fixture('search_full_ytmusic.json')),
      );
      final r = await repoWith(adapter).search('queen', SearchSource.ytMusic);
      expect(r.tracks.first.title, 'Bohemian Rhapsody');
      expect(r.tracks.first.artist, 'Queen');
      expect(r.tracks.first.durationSeconds, 355);
      expect(r.tracks.first.coverUrl, isNotNull);
      expect(r.artists.first.name, 'Queen');
      expect(r.albums, isNotEmpty);
      final uri = adapter.requests.single.uri;
      expect(uri.path, '/api/search/full');
      expect(uri.queryParameters, {'q': 'queen', 'source': 'ytmusic'});
    });

    test('link: resposta real de álbum do Deezer', () async {
      final adapter = FakeAdapter(
        (_) async => jsonBody(fixture('resolve_deezer_album.json')),
      );
      final link = await repoWith(
        adapter,
      ).resolve('https://www.deezer.com/album/12047952');
      expect(link.kind, 'album');
      expect(link.sourceLabel, 'Deezer');
      expect(link.title, contains('Abbey Road'));
      expect(link.total, 17);
      expect(link.tracks, hasLength(3));
      expect(link.tracks.first.provider, 'deezer');
      expect(
        adapter.requests.single.uri.queryParameters['url'],
        contains('deezer.com'),
      );
    });

    test('erros viram ApiException com mensagem em português', () async {
      Future<ApiException> errorFor(FakeAdapter adapter) async {
        try {
          await repoWith(adapter).search('x', SearchSource.spotify);
          fail('deveria lançar');
        } on ApiException catch (e) {
          return e;
        }
      }

      expect(
        (await errorFor(
          FakeAdapter((_) async => jsonBody({}, status: 500)),
        )).kind,
        ApiErrorKind.servidor,
      );
      expect(
        (await errorFor(
          FakeAdapter((_) async => jsonBody({}, status: 401)),
        )).kind,
        ApiErrorKind.naoAutorizado,
      );
      expect(
        (await errorFor(
          FakeAdapter((_) async => jsonBody({}, status: 400)),
        )).statusCode,
        400,
      );
      expect(
        (await errorFor(
          FakeAdapter(
            (o) async => throw DioException.connectionTimeout(
              requestOptions: o,
              timeout: const Duration(seconds: 1),
            ),
          ),
        )).kind,
        ApiErrorKind.tempoEsgotado,
      );
      expect(
        ApiErrorKind.semConexao.message,
        'Não foi possível conectar. Verifique sua internet.',
      );
    });
  });

  group('HttpPlaybackRepository (qualidade)', () {
    PlaybackRepository repoWith(FakeAdapter adapter) => HttpPlaybackRepository(
      createDio(baseUrl: 'https://s.com')..httpClientAdapter = adapter,
    );

    test('stream e download levam o token e o nível pedido', () async {
      final adapter = FakeAdapter((_) async => jsonBody({'token': 'tk'}));
      final repo = repoWith(adapter);
      final stream = await repo.streamUrl('t1', quality: 'normal');
      expect(stream.path, '/api/tracks/t1/stream');
      expect(stream.queryParameters, {'t': 'tk', 'quality': 'normal'});
      final download = await repo.downloadUrl('t1');
      expect(download.queryParameters['quality'], 'original');
    });

    test('lote de qualidades: resposta real do servidor', () async {
      final adapter = FakeAdapter(
        (_) async => jsonBody({
          'spotify:abc': {
            'original': {'label': 'FLAC 16/44.1', 'rank': 40},
            'high': {'label': 'MP3 320', 'rank': 30},
            'normal': {'label': 'AAC 160', 'rank': 20},
            'low': {'label': 'AAC 96', 'rank': 10},
          },
        }),
      );
      final q = await repoWith(adapter).qualities(['spotify:abc', 'deezer:1']);
      expect(q.keys, ['spotify:abc']);
      expect(q['spotify:abc']!['normal']!.label, 'AAC 160');
      expect(q['spotify:abc']!['original']!.rank, 40);
      expect(adapter.requests.single.uri.path, '/api/tracks/qualities');
      expect(adapter.requests.single.data, {
        'refs': ['spotify:abc', 'deezer:1'],
      });
      expect(await repoWith(adapter).qualities(const []), isEmpty);
    });
  });

  group('ServerStatus', () {
    Map<String, dynamic> base() => {
      'storage': {
        'tracks': 2,
        'permanent': 1,
        'cache': 1,
        'bytes': 10,
        'bytes_permanent': 5,
        'bytes_cache': 5,
      },
      'queue': {'waiting': 0, 'active': 0},
      'deemix': {'available': true},
    };

    test('servidor antigo: sem qualidade nem Spotify', () {
      final s = ServerStatus.fromJson(base());
      expect(s.quality, isNull);
      expect(s.spotify, isNull);
    });

    test('lê a qualidade e o teste do Spotify', () {
      final s = ServerStatus.fromJson({
        ...base(),
        'quality': {
          'lossless': 3,
          'high': 4,
          'medium': 1,
          'low': 2,
          'unknown': 0,
          'upgrades_pending': 5,
          'upgrades_waiting': 6,
          'upgrades_done': 7,
          'lidarr': true,
        },
        'spotify': {
          'checked_at': '2026-10-12T13:49:22.514675+00:00',
          'library_version': '3.9.2',
          'library_ok': false,
          'isrc_ok': true,
          'ok': false,
          'failures': {'busca': 'HTTP 400'},
          'update': 'nenhuma versão mais nova',
        },
      });
      final q = s.quality!;
      expect([q.lossless, q.high, q.medium, q.low], [3, 4, 1, 2]);
      expect([q.upgradesPending, q.upgradesWaiting, q.upgradesDone], [5, 6, 7]);
      expect(q.lidarr, isTrue);
      final sp = s.spotify!;
      expect(sp.ok, isFalse);
      expect(sp.libraryVersion, '3.9.2');
      expect(sp.failures, {'busca': 'HTTP 400'});
      expect(sp.checkedAt, isNotNull);
    });
  });
}

/// Obtém um `Ref` real de um container de teste.
abstract final class _RefHolder {
  static Ref of(ProviderContainer container) => container.read(_refProvider);
  static final _refProvider = Provider<Ref>((ref) => ref);
}
