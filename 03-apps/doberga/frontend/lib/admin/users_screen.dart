import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/http.dart';
import '../core/widgets.dart';
import '../data/api.dart';
import '../data/models.dart';

/// Página Usuários (só admin). As contas nascem no Authentik (grupo
/// doberga_users) e aparecem aqui no primeiro login. Daqui o admin desativa,
/// reativa e desconecta aparelhos. O conteúdo dos espaços não aparece.
class UsersScreen extends ConsumerStatefulWidget {
  const UsersScreen({super.key});

  @override
  ConsumerState<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends ConsumerState<UsersScreen> {
  late Future<List<AdminUser>> _users = ref.read(apiProvider).users();

  void _reload() => setState(() => _users = ref.read(apiProvider).users());

  Future<void> _run(Future<void> Function() action, String done) async {
    try {
      await action();
      if (mounted) toast(context, done);
      _reload();
    } on Object catch (e) {
      if (mounted) toast(context, describeError(e));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Usuários')),
    body: FutureBuilder<List<AdminUser>>(
      future: _users,
      builder: (context, snap) {
        if (snap.hasError) return ErrorView(snap.error!, onRetry: _reload);
        final users = snap.data;
        if (users == null) return const Center(child: CircularProgressIndicator());
        final api = ref.read(apiProvider);
        return RefreshIndicator(
          onRefresh: () async => _reload(),
          child: ListView(
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Para dar acesso, ponha a pessoa no grupo doberga_users do Authentik. '
                    'Admin é quem está em doberga_admins.'),
              ),
              for (final u in users)
                ListTile(
                  leading: CircleAvatar(child: Text(u.name.isEmpty ? '?' : u.name[0].toUpperCase())),
                  title: Text(u.name + (u.isAdmin ? ' · admin' : '')),
                  subtitle: Text([
                    u.email ?? u.username,
                    if (u.disabled) 'desativada',
                    '${u.spaces} espaço${u.spaces == 1 ? '' : 's'}',
                    '${u.sessions} aparelho${u.sessions == 1 ? '' : 's'}',
                  ].join(' · ')),
                  trailing: PopupMenuButton<String>(
                    onSelected: (action) async {
                      if (action == 'logout') {
                        await _run(() => api.logoutUser(u.id), 'Aparelhos desconectados.');
                        return;
                      }
                      final ok = await confirm(
                        context,
                        title: u.disabled ? 'Reativar ${u.name}?' : 'Desativar ${u.name}?',
                        message: u.disabled
                            ? null
                            : 'A pessoa não entra mais. Nada é apagado: espaços e grupos ficam.',
                        ok: u.disabled ? 'Reativar' : 'Desativar',
                      );
                      if (ok) {
                        await _run(() => api.setUserDisabled(u.id, !u.disabled),
                            u.disabled ? 'Conta reativada.' : 'Conta desativada.');
                      }
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'logout', child: Text('Desconectar aparelhos')),
                      PopupMenuItem(value: 'toggle', child: Text(u.disabled ? 'Reativar' : 'Desativar')),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    ),
  );
}
