import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/models/account.dart';
import '../../data/repositories/account_repository.dart';
import '../auth/session.dart';

/// A própria conta (cartão "Conta" em Ajustes). Nulo sem servidor.
final myAccountProvider = FutureProvider.autoDispose<Account?>((ref) async {
  final online = ref.watch(sessionProvider.select((s) => s.canUseServer));
  ref.watch(sessionProvider.select((s) => s.username));
  if (!online) return null;
  return ref.read(accountRepositoryProvider).myAccount();
});

/// Pessoas do servidor (tela "Usuários", só admin).
final usersPageProvider = FutureProvider.autoDispose<UsersPage>(
  (ref) => ref.read(accountRepositoryProvider).users(),
);

/// Abre um endereço no navegador (página do Authentik). Trocado nos testes.
final externalLinkProvider = Provider<Future<void> Function(String url)>(
  (ref) => (url) async {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  },
);
