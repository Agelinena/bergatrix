import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Ponte com o `audio_service`: notificação de mídia e tela de bloqueio no
/// Android (e Media Session na web). Os botões da notificação chamam as
/// funções que o player registra em [onCommand].
class BergaAudioHandler extends BaseAudioHandler with SeekHandler {
  /// Recebe "play", "pause", "next", "previous", "stop" e "seek".
  void Function(String command, [Duration? position])? onCommand;

  @override
  Future<void> play() async => onCommand?.call('play');

  @override
  Future<void> pause() async => onCommand?.call('pause');

  @override
  Future<void> skipToNext() async => onCommand?.call('next');

  @override
  Future<void> skipToPrevious() async => onCommand?.call('previous');

  @override
  Future<void> stop() async => onCommand?.call('stop');

  @override
  Future<void> seek(Duration position) async =>
      onCommand?.call('seek', position);

  /// Atualiza a faixa mostrada na notificação.
  void showTrack({
    required String id,
    required String title,
    required String artist,
    required String album,
    Duration? duration,
    String? coverUrl,
  }) {
    mediaItem.add(
      MediaItem(
        id: id,
        title: title,
        artist: artist,
        album: album,
        duration: duration,
        artUri: coverUrl == null ? null : Uri.tryParse(coverUrl),
      ),
    );
  }

  /// Atualiza botões, estado e posição da notificação.
  void showState({
    required bool playing,
    required bool loading,
    required Duration position,
  }) {
    playbackState.add(
      playbackState.value.copyWith(
        controls: [
          MediaControl.skipToPrevious,
          playing ? MediaControl.pause : MediaControl.play,
          MediaControl.skipToNext,
        ],
        systemActions: const {MediaAction.seek},
        androidCompactActionIndices: const [0, 1, 2],
        processingState: loading
            ? AudioProcessingState.loading
            : AudioProcessingState.ready,
        playing: playing,
        updatePosition: position,
      ),
    );
  }
}

/// Inicia o `audio_service`. Devolve nulo onde não há suporte (ex.: Linux
/// nos testes) em vez de impedir o app de abrir.
Future<BergaAudioHandler?> initMediaNotification() async {
  try {
    return await AudioService.init(
      builder: BergaAudioHandler.new,
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.bergastream.app.audio',
        androidNotificationChannelName: 'Reprodução',
        androidNotificationOngoing: true,
        // Silhueta branca: o ícone colorido do app vira um quadrado branco
        // na barra de status.
        androidNotificationIcon: 'drawable/ic_stat_bergastream',
      ),
    );
  } on Object catch (e) {
    debugPrint('audio_service indisponível: $e');
    return null;
  }
}

/// Definido em `main.dart`; nulo nos testes e onde não há suporte.
final mediaNotificationProvider = Provider<BergaAudioHandler?>((ref) => null);
