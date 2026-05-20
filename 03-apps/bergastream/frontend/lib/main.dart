import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'app.dart';
import 'providers/auth_provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Inicializa o background audio antes do runApp.  Necessário para
  // Android (controles de notificação + manter o áudio tocando em
  // background).  Pulamos no web — não há background audio service na
  // web e o init falharia.
  if (!kIsWeb) {
    try {
      await JustAudioBackground.init(
        androidNotificationChannelId: 'xyz.bergaestudio.bergastream.audio',
        androidNotificationChannelName: 'BergaStream',
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
      );
    } catch (e) {
      debugPrint('[main] JustAudioBackground.init failed (non-fatal): $e');
    }
  }

  final container = ProviderContainer();
  await container.read(authProvider.notifier).initialize();

  // Note: loading overlay removal is handled in web/index.html via the
  // 'flutter-first-frame' event — no dart:html needed here.

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const BergaStreamApp(),
    ),
  );
}
