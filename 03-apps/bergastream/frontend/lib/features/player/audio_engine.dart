import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart' as ja;

/// O que o player precisa de um motor de áudio. Separado para os testes
/// usarem um motor falso (o `just_audio` precisa da plataforma).
abstract interface class AudioEngine {
  Stream<Duration> get positionStream;
  Stream<Duration?> get durationStream;

  /// Emite quando a faixa termina sozinha.
  Stream<void> get completedStream;

  Duration get position;

  Future<void> setUrl(Uri url);

  /// Arquivo baixado no aparelho (Seção 7.3: local primeiro).
  Future<void> setFile(String path);
  void play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> stop();
  Future<void> dispose();
}

class JustAudioEngine implements AudioEngine {
  JustAudioEngine() {
    // Foco de áudio (Android): pausa em ligações e abaixa com avisos.
    unawaited(
      AudioSession.instance.then(
        (s) => s.configure(const AudioSessionConfiguration.music()),
      ),
    );
  }

  final _player = ja.AudioPlayer();

  @override
  Stream<Duration> get positionStream => _player.positionStream;

  @override
  Stream<Duration?> get durationStream => _player.durationStream;

  @override
  Stream<void> get completedStream => _player.processingStateStream
      .where((s) => s == ja.ProcessingState.completed)
      .map((_) {});

  @override
  Duration get position => _player.position;

  @override
  Future<void> setUrl(Uri url) async {
    // Navegador: o just_audio 0.10 guarda a fonte anterior em cache no
    // player web (a playlist interna tem id fixo) e a troca de música tocava
    // de novo a primeira. Parar descarta esse player e a próxima carga cria
    // um novo. Só na web: no Android o "stop" tiraria o serviço de mídia do
    // primeiro plano (tela bloqueada).
    if (kIsWeb) await _player.stop();
    await _player.setUrl(url.toString());
  }

  @override
  Future<void> setFile(String path) => _player.setFilePath(path);

  /// Não espera: o `play()` do just_audio só termina quando a faixa para.
  @override
  void play() => unawaited(_player.play());

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> dispose() => _player.dispose();
}

final audioEngineProvider = Provider<AudioEngine>((ref) {
  final engine = JustAudioEngine();
  ref.onDispose(engine.dispose);
  return engine;
});
