import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';

import 'app/app.dart';
import 'core/platform/app_platform.dart';
import 'core/storage/key_value_store.dart';
import 'features/auth/session.dart';
import 'features/downloads/file_fetcher.dart';
import 'features/player/media_notification.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Windows/Linux: o just_audio toca pelo media_kit (libmpv). No Android e
  // na web não faz nada.
  JustAudioMediaKit.ensureInitialized(linux: true, windows: true);
  final platform = AppPlatform.detect();
  final store = SecureKeyValueStore();
  final storage = SessionStorage(
    store,
    prefix: SessionStorage.prefixFor(platform),
  );
  final session = await storage.load(
    defaultServer: platform.isWeb ? webServerAddress() : null,
  );

  final mediaNotification = await initMediaNotification();
  configureDownloadNotifications();

  runApp(
    ProviderScope(
      overrides: [
        appPlatformProvider.overrideWithValue(platform),
        keyValueStoreProvider.overrideWithValue(store),
        sessionStorageProvider.overrideWithValue(storage),
        initialSessionProvider.overrideWithValue(session),
        mediaNotificationProvider.overrideWithValue(mediaNotification),
      ],
      child: const BergastreamApp(),
    ),
  );
}
