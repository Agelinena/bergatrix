import 'dart:async';
import 'dart:math';

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

  /// Se o motor está tocando. Muda sem o app pedir quando o sistema pausa
  /// (fone/Bluetooth desconectado, ligação, outro app tocando).
  Stream<bool> get playingStream;

  /// Erros do motor no meio da faixa (stream cortado, arquivo trocado).
  Stream<Object> get errorStream;

  Duration get position;

  Future<void> setUrl(Uri url);

  /// Arquivo baixado no aparelho (Seção 7.3: local primeiro).
  Future<void> setFile(String path);
  void play();
  Future<void> pause();

  /// 0 (mudo) a 1 (volume cheio do aparelho), em amplitude (linear).
  Future<void> setVolume(double volume);

  /// Ganho acima do volume cheio, em dB (normalização das músicas baixas).
  /// Até [maxBoostDb]; 0 desliga.
  Future<void> setBoost(double db);

  /// Quanto o motor consegue subir: Android (LoudnessEnhancer) 12 dB,
  /// computador (mpv) 6 dB, navegador 0 (o áudio da página não passa de
  /// 100%).
  double get maxBoostDb;
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

  /// Android: ganho acima de 100% pelo LoudnessEnhancer do sistema.
  static final bool _android =
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Windows/Linux: o mpv (media_kit) aplica o volume numa curva cúbica
  /// (volume 50 = 0,125 de amplitude) e aceita até 130.
  static final bool _mpv =
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.windows);

  final _enhancer = ja.AndroidLoudnessEnhancer();
  late final _player = _android
      ? ja.AudioPlayer(
          audioPipeline: ja.AudioPipeline(androidAudioEffects: [_enhancer]),
        )
      : ja.AudioPlayer();

  double _volume = 1;
  double _boostDb = 0;

  @override
  Stream<Duration> get positionStream => _player.positionStream;

  @override
  Stream<Duration?> get durationStream => _player.durationStream;

  @override
  Stream<void> get completedStream => _player.processingStateStream
      .where((s) => s == ja.ProcessingState.completed)
      .map((_) {});

  @override
  Stream<bool> get playingStream => _player.playingStream;

  @override
  Stream<Object> get errorStream => _player.errorStream;

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
  double get maxBoostDb => _android
      ? 12
      : _mpv
      ? 6
      : 0;

  @override
  Future<void> setVolume(double volume) {
    _volume = volume.clamp(0.0, 1.0);
    return _push();
  }

  @override
  Future<void> setBoost(double db) async {
    final next = db.clamp(0.0, maxBoostDb);
    if ((next - _boostDb).abs() < 0.01) return;
    _boostDb = next;
    if (_android) {
      await _enhancer.setTargetGain(next);
      await _enhancer.setEnabled(next > 0);
    }
    await _push();
  }

  Future<void> _push() {
    if (_mpv) {
      // Amplitude pedida → volume do mpv (inverso da curva cúbica); o ganho
      // entra aqui (até 130 = +6,8 dB).
      final amplitude = _volume * pow(10, _boostDb / 20);
      return _player.setVolume(
        (pow(amplitude, 1 / 3).toDouble()).clamp(0.0, 1.3),
      );
    }
    return _player.setVolume(_volume);
  }

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
