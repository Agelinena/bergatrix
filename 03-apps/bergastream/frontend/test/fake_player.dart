import 'dart:async';

import 'package:bergastream/core/network/api_error.dart';
import 'package:bergastream/data/models/search_result.dart';
import 'package:bergastream/data/repositories/playback_repository.dart';
import 'package:bergastream/features/player/audio_engine.dart';

/// Motor de áudio falso: registra os comandos e deixa o teste emitir
/// posição, duração e fim da faixa.
class FakeAudioEngine implements AudioEngine {
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration?>.broadcast();
  final _completed = StreamController<void>.broadcast();

  final urls = <Uri>[];
  final log = <String>[];
  Duration currentPosition = Duration.zero;
  bool playing = false;

  void emitPosition(Duration p) {
    currentPosition = p;
    _position.add(p);
  }

  void emitDuration(Duration d) => _duration.add(d);
  void complete() => _completed.add(null);

  @override
  Stream<Duration> get positionStream => _position.stream;
  @override
  Stream<Duration?> get durationStream => _duration.stream;
  @override
  Stream<void> get completedStream => _completed.stream;
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

  /// Se definido, `prepare` espera este futuro (para testar troca de faixa
  /// no meio do preparo).
  Completer<void>? gate;

  /// Esperas por faixa (título): simula respostas fora de ordem.
  final gates = <String, Completer<void>>{};

  final prepared = <String>[];
  int statusCalls = 0;

  @override
  Future<PreparedTrack> prepare(SearchResult track) async {
    prepared.add(track.title);
    if (gate != null) await gate!.future;
    if (gates[track.title] != null) await gates[track.title]!.future;
    if (failPrepare) throw const ApiException(ApiErrorKind.servidor);
    return PreparedTrack('id-${track.externalId}', initial);
  }

  @override
  Future<TrackReadiness> status(String trackId) async {
    final i = statusCalls.clamp(0, statuses.length - 1);
    statusCalls++;
    return statuses[i];
  }

  @override
  Future<Uri> streamUrl(String trackId) async =>
      Uri.parse('https://s.com/api/tracks/$trackId/stream?t=x');

  @override
  Future<Uri> downloadUrl(String trackId) async =>
      Uri.parse('https://s.com/api/tracks/$trackId/download?t=x');
}

SearchResult song(String name) => SearchResult(
  provider: 'spotify',
  externalId: name,
  title: name,
  artist: 'Artista $name',
  album: 'Álbum',
  durationSeconds: 200,
);
