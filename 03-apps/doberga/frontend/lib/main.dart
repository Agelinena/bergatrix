import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'auth/session.dart';
import 'core/http.dart';
import 'core/storage.dart';
import 'spaces/invite.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = SecureKeyValueStore();
  final storage = SessionStorage(store);
  // Na web, o servidor é o próprio domínio que serve o app.
  final session = await storage.load(
    defaultServer: kIsWeb ? webServerAddress() : null,
  );
  // Link de convite aberto no navegador (/convite/<token>): guardado para
  // depois do login.
  if (kIsWeb) {
    final token = inviteToken(Uri.base.toString());
    if (token != null && Uri.base.path.startsWith('/convite/')) {
      await PendingInvite(store).save(token);
    }
  }
  runApp(
    ProviderScope(
      overrides: [
        keyValueStoreProvider.overrideWithValue(store),
        sessionStorageProvider.overrideWithValue(storage),
        initialSessionProvider.overrideWithValue(session),
      ],
      child: const DobergaApp(),
    ),
  );
}
