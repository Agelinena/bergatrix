import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:timeago/timeago.dart' as timeago;
import 'app.dart';
import 'core/logger.dart';
import 'providers/auth_provider.dart';
import 'providers/player_provider.dart';

/// Master switch for the background-audio integration.
///
/// When true: JustAudioBackground.init runs at startup AND
/// AudioPlayerService uses MediaItem as the AudioSource tag.  Together
/// these power the lockscreen / notification media controls.
///
/// MUST match the constant in audio_player_service.dart's
/// `_useBackgroundMediaItem`.
const _enableBackgroundAudio = true;

/// Global init error from JustAudioBackground.init.  Surfaced into the UI
/// via a SnackBar on the first frame so the user can SEE that background
/// audio failed (otherwise the player just spins forever on Android).
String? backgroundInitError;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Captura debugPrint num buffer em memória que a tela de Configurações > Logs
  // pode renderizar.  Antes de qualquer outro setup para que mensagens do
  // próprio JustAudioBackground.init() já apareçam lá.
  AppLogger.install();

  // Localised "há 3 semanas" / "há 6 dias" labels for the playlist
  // "Adicionada em" column and other relative timestamps.
  timeago.setLocaleMessages('pt_BR', timeago.PtBrMessages());

  // Inicializa o background audio antes do runApp.  Necessário para
  // Android (controles de notificação + manter o áudio tocando em
  // background).  Pulamos no web — não há background audio service na
  // web e o init falharia.
  if (!kIsWeb && _enableBackgroundAudio) {
    try {
      await JustAudioBackground.init(
        androidNotificationChannelId: 'xyz.bergaestudio.bergastream.audio',
        androidNotificationChannelName: 'BergaStream',
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
      );
      debugPrint('[main] JustAudioBackground initialised OK');
    } catch (e, st) {
      backgroundInitError = '$e';
      debugPrint('[main] JustAudioBackground.init FAILED: $e\n$st');
    }
  } else if (!kIsWeb) {
    debugPrint('[main] Background audio DISABLED via _enableBackgroundAudio flag');
  }

  final container = ProviderContainer();
  await container.read(authProvider.notifier).initialize();

  // Note: loading overlay removal is handled in web/index.html via the
  // 'flutter-first-frame' event — no dart:html needed here.

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const _RootWithErrorListener(child: BergaStreamApp()),
    ),
  );
}

/// Wraps the app to surface global audio errors as SnackBars instead of
/// failing silently.
class _RootWithErrorListener extends ConsumerStatefulWidget {
  final Widget child;
  const _RootWithErrorListener({required this.child});

  @override
  ConsumerState<_RootWithErrorListener> createState() => _RootWithErrorListenerState();
}

class _RootWithErrorListenerState extends ConsumerState<_RootWithErrorListener> {
  bool _shownInitError = false;
  PlayerStatus? _lastStatus;

  @override
  void initState() {
    super.initState();
    if (backgroundInitError != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _showInitError());
    }
  }

  void _showInitError() {
    if (_shownInitError) return;
    _shownInitError = true;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.showSnackBar(SnackBar(
      backgroundColor: Colors.deepOrange,
      duration: const Duration(seconds: 8),
      content: Text(
        'Áudio em background falhou ao iniciar:\n$backgroundInitError',
        style: const TextStyle(fontSize: 12),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    // Listen for player status transitions into "error" to show a SnackBar.
    ref.listen<PlayerState>(playerProvider, (prev, next) {
      if (next.status == PlayerStatus.error && _lastStatus != PlayerStatus.error) {
        final messenger = ScaffoldMessenger.maybeOf(context);
        final msg = next.lastError != null
            ? 'Erro ao reproduzir: ${next.lastError}'
            : 'Erro ao reproduzir áudio. Verifique a conexão.';
        messenger?.showSnackBar(SnackBar(
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 8),
          content: Text(msg, style: const TextStyle(fontSize: 12)),
        ));
      }
      _lastStatus = next.status;
    });
    return widget.child;
  }
}
