import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/storage.dart';

/// Convite que chegou pelo link (`/convite/<token>`) e ainda não foi visto.
/// Fica guardado para sobreviver à ida e volta do login pelo Authentik.
class PendingInvite {
  PendingInvite(this._store);

  final KeyValueStore _store;
  static const _key = 'pending_invite';

  Future<void> save(String token) => _store.write(_key, token);

  Future<String?> take() async {
    final token = await _store.read(_key);
    if (token != null) await _store.delete(_key);
    return token;
  }
}

final pendingInviteProvider = Provider<PendingInvite>(
  (ref) => PendingInvite(ref.watch(keyValueStoreProvider)),
);

/// Token de um link de convite (`https://…/convite/<token>`) ou do próprio
/// token colado; nulo se não parecer um convite.
String? inviteToken(String input) {
  final value = input.trim();
  if (value.isEmpty) return null;
  final uri = Uri.tryParse(value);
  if (uri != null && uri.pathSegments.length >= 2) {
    final i = uri.pathSegments.indexOf('convite');
    if (i >= 0 && i + 1 < uri.pathSegments.length) return uri.pathSegments[i + 1];
  }
  return RegExp(r'^[A-Za-z0-9_-]{16,100}$').hasMatch(value) ? value : null;
}
