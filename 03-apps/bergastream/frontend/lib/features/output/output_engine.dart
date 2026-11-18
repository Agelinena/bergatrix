import 'dart:async';

import '../../data/models/search_result.dart';
import '../player/audio_engine.dart';

/// Aparelho na rede que toca no lugar do celular/computador (Chromecast,
/// TV por DLNA). Busca a música direto do servidor pela URL com token curto.
abstract interface class RemoteRenderer implements AudioEngine {
  /// Nome do aparelho ("TV da sala").
  String get name;

  /// "Chromecast", "DLNA".
  String get kind;

  /// Título, artista e capa da próxima música (o aparelho mostra na tela).
  void describe(SearchResult track);

  /// A conexão com o aparelho caiu (desligou, saiu da rede).
  Stream<void> get lostStream;
}

/// O motor que o player usa: o do aparelho ou, ao "Tocar em" um Chromecast ou
/// TV, o remoto. Os streams são sempre os mesmos (o player assina uma vez) e
/// passam a vir do motor ativo.
class OutputEngine implements AudioEngine {
  OutputEngine(this.local) {
    _bind(local);
  }

  final AudioEngine local;
  RemoteRenderer? _remote;

  /// O aparelho remoto em uso (nulo = toca aqui).
  RemoteRenderer? get remote => _remote;

  AudioEngine get _active => _remote ?? local;

  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration?>.broadcast();
  final _completed = StreamController<void>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _errors = StreamController<Object>.broadcast();
  final _lost = StreamController<void>.broadcast();
  final _subs = <StreamSubscription<Object?>>[];

  /// O aparelho remoto saiu (conexão caiu): o player volta a tocar aqui.
  Stream<void> get lostStream => _lost.stream;

  void _bind(AudioEngine engine) {
    for (final s in _subs) {
      s.cancel();
    }
    _subs
      ..clear()
      ..add(engine.positionStream.listen(_position.add))
      ..add(engine.durationStream.listen(_duration.add))
      ..add(engine.completedStream.listen(_completed.add))
      ..add(engine.playingStream.listen(_playing.add))
      ..add(engine.errorStream.listen(_errors.add));
    if (engine is RemoteRenderer) {
      _subs.add(engine.lostStream.listen(_lost.add));
    }
  }

  /// Passa a tocar em [renderer] (nulo = volta para aqui). O motor que sai
  /// para; quem chama carrega a música atual no novo.
  Future<void> use(RemoteRenderer? renderer) async {
    if (identical(renderer, _remote)) return;
    final old = _remote;
    if (old == null) {
      await local.pause();
    } else {
      try {
        await old.stop();
      } on Object {
        // aparelho já fora
      }
      await old.dispose();
    }
    _remote = renderer;
    _bind(_active);
  }

  /// Metadados da música que vai tocar (só o aparelho remoto usa).
  void describe(SearchResult track) => _remote?.describe(track);

  @override
  Stream<Duration> get positionStream => _position.stream;

  @override
  Stream<Duration?> get durationStream => _duration.stream;

  @override
  Stream<void> get completedStream => _completed.stream;

  @override
  Stream<bool> get playingStream => _playing.stream;

  @override
  Stream<Object> get errorStream => _errors.stream;

  @override
  Duration get position => _active.position;

  @override
  Future<void> setUrl(Uri url) => _active.setUrl(url);

  @override
  Future<void> setFile(String path) => _active.setFile(path);

  @override
  void play() => _active.play();

  @override
  Future<void> pause() => _active.pause();

  @override
  Future<void> setVolume(double volume) => _active.setVolume(volume);

  @override
  Future<void> setBoost(double db) => _active.setBoost(db);

  @override
  double get maxBoostDb => _active.maxBoostDb;

  @override
  Future<void> seek(Duration position) => _active.seek(position);

  @override
  Future<void> stop() => _active.stop();

  @override
  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    await _remote?.dispose();
    await local.dispose();
    for (final c in [
      _position,
      _duration,
      _completed,
      _playing,
      _errors,
      _lost,
    ]) {
      await c.close();
    }
  }
}
