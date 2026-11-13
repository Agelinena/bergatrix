import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../admin/users_screen.dart';
import '../auth/session.dart';
import '../core/http.dart';
import '../core/widgets.dart';
import '../local/local_store.dart';
import '../spaces/spaces_screen.dart';
import '../sync/sync_controller.dart';
import 'prefs.dart';

const appVersion = '0.1.0';

Future<void> openSettings(BuildContext context) => Navigator.of(
  context,
).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));

Future<void> _push(BuildContext context, Widget screen) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  Future<void> _save(BuildContext context, WidgetRef ref, Map<String, dynamic> changes) async {
    try {
      await ref.read(prefsProvider.notifier).save(changes);
    } on Object catch (e) {
      if (context.mounted) toast(context, describeError(e));
    }
  }

  Future<void> _logout(BuildContext context, WidgetRef ref) async {
    final pending = ref.read(storeProvider).pendingCount;
    final ok = await confirm(
      context,
      title: 'Sair do Doberga?',
      message: pending > 0
          ? 'Há $pending alteraç${pending == 1 ? 'ão' : 'ões'} ainda não enviada${pending == 1 ? '' : 's'}. '
              'Elas ficam guardadas neste aparelho e são enviadas quando você entrar de novo.'
          : 'Os dados continuam guardados neste aparelho para quando você entrar de novo.',
      ok: 'Sair',
    );
    if (ok) await ref.read(sessionProvider.notifier).logout();
  }

  Future<void> _wipe(BuildContext context, WidgetRef ref) async {
    final ok = await confirm(
      context,
      title: 'Sair e apagar os dados deste aparelho?',
      message: 'Use num aparelho que não é seu. O que ainda não foi enviado se perde.',
      ok: 'Apagar e sair',
    );
    if (!ok) return;
    final userId = ref.read(sessionProvider).user?.id;
    // Fecha o banco antes de apagar o arquivo (no Windows, arquivo aberto não se apaga).
    await ref.read(storeProvider).close();
    await ref.read(sessionProvider.notifier).logout();
    if (userId != null) await deleteLocalStore(userId);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final user = session.user;
    final prefs = ref.watch(prefsProvider).value;
    final sync = ref.watch(syncProvider);
    final spaces = ref.watch(spacesProvider).value ?? const [];
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Ajustes')),
      body: ListView(
        children: [
          if (user != null)
            ListTile(
              leading: CircleAvatar(child: Text(user.name.isEmpty ? '?' : user.name[0].toUpperCase())),
              title: Text(user.name),
              subtitle: Text(user.email ?? user.username),
              trailing: IconButton(
                tooltip: 'Gerenciar no Authentik',
                icon: const Icon(Icons.open_in_new),
                onPressed: () async {
                  final server = session.server;
                  if (server == null) return;
                  try {
                    final config = await ref.read(sessionProvider.notifier).checkServer(server);
                    final uri = Uri.tryParse(config.accountUrl);
                    if (uri != null) await launchUrl(uri, mode: LaunchMode.externalApplication);
                  } on Object catch (e) {
                    if (context.mounted) toast(context, describeError(e));
                  }
                },
              ),
            ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.workspaces_outline),
            title: const Text('Espaços'),
            subtitle: Text('${spaces.length} espaço${spaces.length == 1 ? '' : 's'}: '
                '${spaces.map((s) => s.name).join(', ')}'),
            onTap: () => _push(context, const SpacesScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.sync),
            title: const Text('Sincronização'),
            subtitle: Text(_syncText(sync)),
            trailing: TextButton(
              onPressed: () => ref.read(syncProvider.notifier).syncNow(),
              child: const Text('Agora'),
            ),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text('Aparência', style: theme.textTheme.titleSmall),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'system', label: Text('Sistema')),
                ButtonSegment(value: 'light', label: Text('Claro')),
                ButtonSegment(value: 'dark', label: Text('Escuro')),
              ],
              selected: {prefs?.theme ?? 'system'},
              onSelectionChanged: (v) => _save(context, ref, {'theme': v.first}),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.notifications_outlined),
            title: const Text('Horário dos avisos'),
            subtitle: Text('Recorrentes do dia, às ${prefs?.notifyHour ?? 9}h'),
            onTap: () async {
              final picked = await showTimePicker(
                context: context,
                initialTime: TimeOfDay(hour: prefs?.notifyHour ?? 9, minute: 0),
                helpText: 'Hora dos avisos',
              );
              if (picked != null && context.mounted) {
                await _save(context, ref, {'notify_hour': picked.hour});
              }
            },
          ),
          SwitchListTile(
            secondary: const Icon(Icons.calendar_view_week),
            title: const Text('Semana começa no domingo'),
            value: prefs?.weekStart == 'sunday',
            onChanged: (v) => _save(context, ref, {'week_start': v ? 'sunday' : 'monday'}),
          ),
          if (user?.isAdmin ?? false) ...[
            const Divider(),
            ListTile(
              leading: const Icon(Icons.admin_panel_settings_outlined),
              title: const Text('Usuários'),
              subtitle: const Text('Quem usa o Doberga (as contas vêm do Authentik)'),
              onTap: () => _push(context, const UsersScreen()),
            ),
          ],
          const Divider(),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Sair'),
            onTap: () => _logout(context, ref),
          ),
          ListTile(
            leading: const Icon(Icons.phonelink_erase),
            title: const Text('Sair e apagar os dados deste aparelho'),
            onTap: () => _wipe(context, ref),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Doberga $appVersion · ${session.server ?? ''}',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  static String _syncText(SyncStatus s) {
    final pending = s.pending > 0 ? ' · ${s.pending} para enviar' : '';
    final last = s.lastSync == null
        ? 'nunca'
        : '${s.lastSync!.day.toString().padLeft(2, '0')}/${s.lastSync!.month.toString().padLeft(2, '0')} '
            '${s.lastSync!.hour.toString().padLeft(2, '0')}:${s.lastSync!.minute.toString().padLeft(2, '0')}';
    return switch (s.phase) {
      SyncPhase.syncing => 'Sincronizando…$pending',
      SyncPhase.offline => 'Sem conexão (última: $last)$pending',
      SyncPhase.upgradeRequired => s.error ?? 'Atualize o app',
      SyncPhase.error => '${s.error ?? 'Falha'}$pending',
      SyncPhase.idle => 'Última: $last$pending',
    };
  }
}
