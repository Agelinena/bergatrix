import 'dart:async';

import 'package:bergastream/core/network/api_error.dart';
import 'package:bergastream/data/models/search_result.dart';
import 'package:bergastream/data/repositories/playback_repository.dart';
import 'package:bergastream/features/output/output_devices.dart';
import 'package:bergastream/features/output/output_engine.dart';
import 'package:bergastream/features/player/audio_engine.dart';

/// Motor de áudio falso: registra os comandos e deixa o teste emitir
/// posição, duração e fim da faixa.
class FakeAudioEngine implements AudioEngine {
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration?>.broadcast();
  final _completed = StreamController<void>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _errors = StreamController<Object>.broadcast();

  final urls = <Uri>[];
  final log = <String>[];

  /// Volume aplicado (fora do [log] para não poluir as sequências).
  double volume = 1;
  final volumes = <double>[];
  Duration currentPosition = Duration.zero;
  bool playing = false;

  void emitPosition(Duration p) {
    currentPosition = p;
    _position.add(p);
  }

  void emitDuration(Duration d) => _duration.add(d);
  void complete() => _completed.add(null);

  /// O sistema pausou/retomou o motor sozinho (ex.: Bluetooth desconectou).
  void systemPause() {
    playing = false;
    log.add('pausa do sistema');
    _playing.add(false);
  }

  void emitError(Object error) => _errors.add(error);

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
  Duration get position => currentPosition;

  @override
  Future<void> setUrl(Uri url) async {
    urls.add(url);
    log.add('setUrl');
  }

  final files = <String>[];

  @override
  Future<void> setFile(String path) async {
    files.add(path);
    log.add('setFile');
  }

  @override
  Future<void> setVolume(double v) async {
    volume = v;
    volumes.add(v);
  }

  /// Ganho acima de 100% pedido (dB) e quanto o motor falso aceita.
  double boost = 0;
  @override
  double maxBoostDb = 12;

  @override
  Future<void> setBoost(double db) async => boost = db.clamp(0, maxBoostDb);

  @override
  void play() {
    playing = true;
    log.add('play');
  }

  @override
  Future<void> pause() async {
    playing = false;
    log.add('pause');
  }

  @override
  Future<void> seek(Duration position) async {
    currentPosition = position;
    log.add('seek ${position.inSeconds}');
  }

  @override
  Future<void> stop() async {
    playing = false;
    log.add('stop');
  }

  @override
  Future<void> dispose() async {}
}

/// Servidor falso: `prepare` devolve [initial] e `status` vai devolvendo
/// [statuses] em sequência (o último se repete).
class FakePlaybackRepository implements PlaybackRepository {
  FakePlaybackRepository({
    this.initial = TrackReadiness.pronta,
    this.statuses = const [TrackReadiness.pronta],
    this.failPrepare = false,
  });

  TrackReadiness initial;
  List<TrackReadiness> statuses;
  bool failPrepare;

  /// Só estas músicas (títulos) falham ao preparar.
  final failTitles = <String>{};

  /// Se definido, `prepare` espera este futuro (para testar troca de faixa
  /// no meio do preparo).
  Completer<void>? gate;

  /// Esperas por faixa (título): simula respostas fora de ordem.
  final gates = <String, Completer<void>>{};

  final prepared = <String>[];
  int statusCalls = 0;

  /// Títulos adiantados pela pré-busca (`prefetch`).
  final prefetched = <String>[];

  @override
  Future<PreparedTrack> prepare(
    SearchResult track, {
    bool prefetch = false,
  }) async {
    prepared.add(track.title);
    if (prefetch) prefetched.add(track.title);
    if (gate != null) await gate!.future;
    if (gates[track.title] != null) await gates[track.title]!.future;
    if (failPrepare || failTitles.contains(track.title)) {
      throw const ApiException(ApiErrorKind.servidor);
    }
    return PreparedTrack('id-${track.externalId}', initial);
  }

  @override
  Future<TrackReadiness> status(String trackId) async {
    final i = statusCalls.clamp(0, statuses.length - 1);
    statusCalls++;
    return statuses[i];
  }

  /// Níveis pedidos (`AudioQuality.api`), na ordem.
  final streamQualities = <String>[];
  final downloadQualities = <String>[];

  /// O que o servidor entrega por faixa ("provider:externalId") e nível.
  Map<String, Map<String, TrackQuality>> serverQualities = {};
  int qualityCalls = 0;

  /// Volume alvo pedido em cada stream (nulo = sem normalizar no servidor).
  final streamNorms = <double?>[];

  /// Faixas "aquecidas" (versão preparada antes de tocar).
  final warmed = <String>[];

  @override
  Future<Uri> streamUrl(
    String trackId, {
    String quality = 'original',
    double? norm,
  }) async {
    streamQualities.add(quality);
    streamNorms.add(norm);
    return Uri.parse(
      'https://s.com/api/tracks/$trackId/stream?t=x&quality=$quality'
      '${norm == null ? '' : '&norm=${norm.round()}'}',
    );
  }

  @override
  Future<void> warm(
    String trackId, {
    String quality = 'original',
    double? norm,
  }) async => warmed.add(trackId);

  @override
  Future<Uri> downloadUrl(String trackId, {String quality = 'original'}) async {
    downloadQualities.add(quality);
    return Uri.parse(
      'https://s.com/api/tracks/$trackId/download?t=x&quality=$quality',
    );
  }

  @override
  Future<Map<String, Map<String, TrackQuality>>> qualities(
    List<String> refs,
  ) async {
    qualityCalls++;
    return {for (final r in refs) r: ?serverQualities[r]};
  }

  /// Volume percebido por faixa ("provider:externalId").
  Map<String, TrackLoudness> serverLoudness = {};
  final redownloaded = <String>[];

  @override
  Future<Map<String, TrackLoudness>> loudness(List<String> refs) async => {
    for (final r in refs) r: ?serverLoudness[r],
  };

  @override
  Future<PreparedTrack> redownload(SearchResult track) async {
    redownloaded.add(track.title);
    return PreparedTrack('id-${track.externalId}', TrackReadiness.baixando);
  }
}

SearchResult song(String name) => SearchResult(
  provider: 'spotify',
  externalId: name,
  title: name,
  artist: 'Artista $name',
  album: 'Álbum',
  durationSeconds: 200,
);

/// Chromecast/TV falso: grava os comandos e deixa o teste avisar o fim da
/// música ou a queda da conexão.
class FakeRenderer extends FakeAudioEngine implements RemoteRenderer {
  FakeRenderer({this.name = 'TV da sala', this.kind = 'Chromecast'});

  @override
  final String name;

  @override
  final String kind;

  final described = <String>[];
  final _lost = StreamController<void>.broadcast();
  bool disposed = false;

  @override
  void describe(SearchResult track) => described.add(track.title);

  @override
  Future<void> setFile(String path) =>
      throw UnsupportedError('remoto não toca arquivo');

  @override
  double get maxBoostDb => 0;

  @override
  Stream<void> get lostStream => _lost.stream;

  void lose() => _lost.add(null);

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

/// Rede falsa: devolve [devices] e conecta em [renderers] pelo id.
class FakeOutputPlatform implements OutputPlatform {
  FakeOutputPlatform({
    this.devices = const [],
    Map<String, RemoteRenderer>? renderers,
  }) : renderers = renderers ?? {};

  final List<OutputDevice> devices;
  final Map<String, RemoteRenderer> renderers;
  int searches = 0;

  @override
  Future<List<OutputDevice>> discover() async {
    searches++;
    return devices;
  }

  @override
  Future<RemoteRenderer> connect(OutputDevice device) async =>
      renderers[device.id] ?? (throw StateError('não conectou'));
}
