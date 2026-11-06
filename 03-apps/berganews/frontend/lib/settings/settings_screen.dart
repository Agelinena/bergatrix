import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../auth/session.dart';
import '../core/files.dart';
import '../core/http.dart';
import '../core/widgets.dart';
import '../data/api.dart';
import '../feeds/feeds_tabs.dart';
import 'appearance_screen.dart';
import 'manage_screens.dart';

const appVersion = '0.1.0';

Future<void> openSettings(BuildContext context) => Navigator.of(
  context,
).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));

Future<void> _push(BuildContext context, Widget screen) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  Future<void> _export(BuildContext context, WidgetRef ref) async {
    try {
      final bytes = await ref.read(apiProvider).exportOpml();
      final message = await saveFile('berganews.opml', bytes, 'text/x-opml');
      if (context.mounted) toast(context, message);
    } on Object catch (e) {
      if (context.mounted) toast(context, describeError(e));
    }
  }

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    final file = await FilePicker.pickFile();
    if (file == null) return;
    try {
      final bytes = await file.readAsBytes();
      final result = await ref.read(apiProvider).importOpml(bytes);
      ref.invalidate(subscriptionsProvider);
      ref.invalidate(foldersProvider);
      if (!context.mounted) return;
      final failed = result.failed.isEmpty
          ? ''
          : ' ${result.failed.length} endereços não serviram.';
      toast(
        context,
        '${result.added} veículos adicionados, ${result.already} já assinados.$failed',
      );
    } on Object catch (e) {
      if (context.mounted) toast(context, describeError(e));
    }
  }

  Future<void> _manageAccount(BuildContext context, WidgetRef ref) async {
    try {
      final config = await ref.read(apiProvider).authConfig();
      final uri = Uri.tryParse(config.accountUrl);
      if (uri != null && config.accountUrl.isNotEmpty) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } on Object catch (e) {
      if (context.mounted) toast(context, describeError(e));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final user = session.user;
    return Scaffold(
      appBar: AppBar(title: const Text('Ajustes')),
      body: ListView(
        children: [
          if (user != null)
            ListTile(
              leading: CircleAvatar(
                child: Text(user.name.isEmpty ? '?' : user.name[0].toUpperCase()),
              ),
              title: Text(user.name),
              subtitle: Text(user.email ?? user.username),
            ),
          ListTile(
            leading: const Icon(Icons.manage_accounts_outlined),
            title: const Text('Gerenciar no Authentik'),
            subtitle: const Text('Nome, e-mail, senha e 2FA'),
            onTap: () => _manageAccount(context, ref),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: const Text('Aparência'),
            subtitle: const Text('Abas, tema, tamanho do texto, idioma'),
            onTap: () => _push(context, const AppearanceScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.rss_feed),
            title: const Text('Veículos'),
            subtitle: const Text('Adicionar, renomear, mudar de pasta, remover'),
            onTap: () => _push(context, const SubscriptionsScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: const Text('Pastas'),
            onTap: () => _push(context, const FoldersScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.file_upload_outlined),
            title: const Text('Importar OPML'),
            subtitle: const Text('De outro leitor (Feedly, Inoreader, FreshRSS…)'),
            onTap: () => _import(context, ref),
          ),
          ListTile(
            leading: const Icon(Icons.file_download_outlined),
            title: const Text('Exportar OPML'),
            subtitle: const Text('Seus veículos e pastas, para backup ou outro leitor'),
            onTap: () => _export(context, ref),
          ),
          if (user?.isAdmin ?? false) ...[
            const Divider(),
            ListTile(
              leading: const Icon(Icons.group_outlined),
              title: const Text('Usuários'),
              subtitle: const Text('Desativar contas e desconectar aparelhos'),
              onTap: () => _push(context, const UsersScreen()),
            ),
          ],
          const Divider(),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Sair'),
            onTap: () async {
              final ok = await confirm(
                context,
                title: 'Sair deste aparelho?',
                ok: 'Sair',
              );
              if (!ok || !context.mounted) return;
              // Pega a sessão antes de fechar a tela (depois o ref não vale).
              final session = ref.read(sessionProvider.notifier);
              Navigator.of(context).popUntil((r) => r.isFirst);
              await session.logout();
            },
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('Berganews'),
            subtitle: Text('Versão $appVersion · ${session.server ?? ''}'),
          ),
        ],
      ),
    );
  }
}
