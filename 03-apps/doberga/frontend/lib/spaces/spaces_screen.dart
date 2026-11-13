import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../auth/session.dart';
import '../core/http.dart';
import '../core/widgets.dart';
import '../data/api.dart';
import '../data/models.dart';
import '../sync/sync_controller.dart';
import 'invite.dart';

Future<void> _push(BuildContext context, Widget screen) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));

Color? spaceColor(Space space) {
  final hex = space.color;
  if (hex == null || hex.length != 7) return null;
  return Color(int.parse('FF${hex.substring(1)}', radix: 16));
}

/// Cores oferecidas ao criar ou editar um grupo.
const groupColors = ['#1F8A5B', '#2155D6', '#C2410C', '#9333EA', '#DB2777', '#0E7490', '#CA8A04'];

class SpaceAvatar extends StatelessWidget {
  const SpaceAvatar(this.space, {super.key});

  final Space space;

  @override
  Widget build(BuildContext context) => CircleAvatar(
    backgroundColor: spaceColor(space) ?? Theme.of(context).colorScheme.primaryContainer,
    foregroundColor: Colors.white,
    child: Icon(space.isPersonal ? Icons.person : Icons.group),
  );
}

/// Ajustes → Espaços: o pessoal e os grupos, criar grupo, entrar por convite.
class SpacesScreen extends ConsumerWidget {
  const SpacesScreen({super.key});

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final name = await askText(context, title: 'Novo grupo', label: 'Nome (ex.: Casa)', ok: 'Criar');
    if (name == null) return;
    try {
      final color = groupColors[DateTime.now().millisecond % groupColors.length];
      final space = await ref.read(apiProvider).createSpace(name, color: color);
      await ref.read(syncProvider.notifier).syncNow();
      if (context.mounted) await _push(context, SpaceScreen(spaceId: space.id));
    } on Object catch (e) {
      if (context.mounted) toast(context, describeError(e));
    }
  }

  Future<void> _join(BuildContext context) async {
    final text = await askText(context, title: 'Entrar num grupo', label: 'Link do convite', ok: 'Abrir');
    if (text == null || !context.mounted) return;
    final token = inviteToken(text);
    if (token == null) {
      toast(context, 'Isso não parece um link de convite.');
      return;
    }
    await _push(context, AcceptInviteScreen(token: token));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final spaces = ref.watch(spacesProvider).value ?? const [];
    return Scaffold(
      appBar: AppBar(title: const Text('Espaços')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _create(context, ref),
        icon: const Icon(Icons.group_add),
        label: const Text('Novo grupo'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 96),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Text(
              'Tudo no app pertence a um espaço: o seu (só seu) ou um grupo, '
              'que você divide com outras pessoas.',
            ),
          ),
          for (final s in spaces)
            ListTile(
              leading: SpaceAvatar(s),
              title: Text(s.name),
              subtitle: Text(s.isPersonal
                  ? 'Só você'
                  : '${s.members.length} pessoa${s.members.length == 1 ? '' : 's'}'
                      '${s.isOwner ? ' · você é dono' : ''}'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _push(context, SpaceScreen(spaceId: s.id)),
            ),
          if (spaces.isEmpty)
            const ListTile(title: Text('Sincronize para ver os seus espaços.')),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.link),
            title: const Text('Entrar num grupo com um link de convite'),
            onTap: () => _join(context),
          ),
        ],
      ),
    );
  }
}

/// Um espaço: membros, convite, renomear, sair, apagar.
class SpaceScreen extends ConsumerWidget {
  const SpaceScreen({super.key, required this.spaceId});

  final String spaceId;

  Future<void> _run(BuildContext context, WidgetRef ref, Future<void> Function(Api api) action,
      {String? done}) async {
    try {
      await action(ref.read(apiProvider));
      await ref.read(syncProvider.notifier).syncNow();
      if (context.mounted && done != null) toast(context, done);
    } on Object catch (e) {
      if (context.mounted) toast(context, describeError(e));
    }
  }

  Future<void> _invite(BuildContext context, WidgetRef ref, Space space) async {
    try {
      final invite = await ref.read(apiProvider).createInvite(space.id);
      final text = 'Entre no grupo "${space.name}" no Doberga: ${invite.url}';
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Convite criado'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Mande este link para quem você quer no grupo. '
                  'Vale por 7 dias, para até 10 pessoas.'),
              const SizedBox(height: 12),
              SelectableText(invite.url),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Fechar')),
            FilledButton.icon(
              onPressed: () => SharePlus.instance.share(ShareParams(text: text)),
              icon: const Icon(Icons.share),
              label: const Text('Compartilhar'),
            ),
          ],
        ),
      );
    } on Object catch (e) {
      if (context.mounted) toast(context, describeError(e));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final spaces = ref.watch(spacesProvider).value ?? const [];
    final me = ref.watch(sessionProvider.select((s) => s.user?.id));
    final space = spaces.where((s) => s.id == spaceId).firstOrNull;
    if (space == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const MessageView(
          icon: Icons.group_off_outlined,
          title: 'Você não está mais neste espaço',
        ),
      );
    }
    final owner = space.isOwner;
    final group = !space.isPersonal;
    return Scaffold(
      appBar: AppBar(
        title: Text(space.name),
        actions: [
          if (owner || space.isPersonal)
            IconButton(
              tooltip: 'Renomear',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () async {
                final name = await askText(context, title: 'Nome do espaço', initial: space.name);
                if (name != null && context.mounted) {
                  await _run(context, ref, (api) => api.updateSpace(space.id, name: name));
                }
              },
            ),
        ],
      ),
      body: ListView(
        children: [
          if (owner || space.isPersonal)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Wrap(
                spacing: 8,
                children: [
                  for (final c in groupColors)
                    InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => _run(context, ref, (api) => api.updateSpace(space.id, color: c)),
                      child: CircleAvatar(
                        radius: 14,
                        backgroundColor: Color(int.parse('FF${c.substring(1)}', radix: 16)),
                        child: space.color == c
                            ? const Icon(Icons.check, size: 16, color: Colors.white)
                            : null,
                      ),
                    ),
                ],
              ),
            ),
          if (space.isPersonal)
            const ListTile(
              leading: Icon(Icons.lock_outline),
              title: Text('Espaço pessoal'),
              subtitle: Text('Só você vê o que estiver aqui. Para dividir, crie um grupo.'),
            ),
          if (group) ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text('Pessoas', style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            for (final m in space.members)
              ListTile(
                leading: CircleAvatar(child: Text(m.name.isEmpty ? '?' : m.name[0].toUpperCase())),
                title: Text(m.userId == me ? '${m.name} (você)' : m.name),
                subtitle: Text(m.isOwner ? 'Dono' : 'Membro'),
                trailing: owner && m.userId != me
                    ? PopupMenuButton<String>(
                        onSelected: (action) async {
                          if (action == 'remove') {
                            final ok = await confirm(context,
                                title: 'Tirar ${m.name} do grupo?',
                                message: 'A pessoa deixa de ver tudo do grupo.',
                                ok: 'Tirar');
                            if (!ok || !context.mounted) return;
                            await _run(context, ref, (api) => api.removeMember(space.id, m.userId));
                          } else {
                            await _run(context, ref,
                                (api) => api.setRole(space.id, m.userId, m.isOwner ? 'member' : 'owner'));
                          }
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: 'role',
                            child: Text(m.isOwner ? 'Tornar membro' : 'Tornar dono'),
                          ),
                          const PopupMenuItem(value: 'remove', child: Text('Tirar do grupo')),
                        ],
                      )
                    : null,
              ),
            if (owner)
              ListTile(
                leading: const Icon(Icons.person_add_alt),
                title: const Text('Convidar pessoas'),
                subtitle: const Text('Gera um link para mandar'),
                onTap: () => _invite(context, ref, space),
              ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('Sair do grupo'),
              onTap: () async {
                final ok = await confirm(context,
                    title: 'Sair de "${space.name}"?',
                    message: 'Você deixa de ver tudo do grupo neste e nos outros aparelhos.',
                    ok: 'Sair');
                if (!ok || !context.mounted || me == null) return;
                await _run(context, ref, (api) => api.removeMember(space.id, me), done: 'Você saiu do grupo.');
                if (context.mounted) Navigator.of(context).maybePop();
              },
            ),
            if (owner)
              ListTile(
                leading: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
                title: Text('Apagar o grupo',
                    style: TextStyle(color: Theme.of(context).colorScheme.error)),
                subtitle: const Text('Apaga tudo do grupo, para todas as pessoas'),
                onTap: () async {
                  final ok = await confirm(context,
                      title: 'Apagar "${space.name}"?',
                      message: 'Listas, recorrentes, eventos e notas do grupo somem para todos. '
                          'Não dá para desfazer.',
                      ok: 'Apagar');
                  if (!ok || !context.mounted) return;
                  await _run(context, ref, (api) => api.deleteSpace(space.id), done: 'Grupo apagado.');
                  if (context.mounted) Navigator.of(context).maybePop();
                },
              ),
          ],
        ],
      ),
    );
  }
}

/// Convite aberto pelo link: mostra o grupo e pede confirmação.
class AcceptInviteScreen extends ConsumerStatefulWidget {
  const AcceptInviteScreen({super.key, required this.token});

  final String token;

  @override
  ConsumerState<AcceptInviteScreen> createState() => _AcceptInviteScreenState();
}

class _AcceptInviteScreenState extends ConsumerState<AcceptInviteScreen> {
  late Future<InvitePreview> _preview = ref.read(apiProvider).previewInvite(widget.token);
  bool _busy = false;

  Future<void> _accept() async {
    setState(() => _busy = true);
    try {
      final space = await ref.read(apiProvider).acceptInvite(widget.token);
      await ref.read(syncProvider.notifier).syncNow();
      if (!mounted) return;
      toast(context, 'Você entrou em "${space.name}".');
      Navigator.of(context).pop();
    } on Object catch (e) {
      if (mounted) toast(context, describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Convite')),
    body: FutureBuilder<InvitePreview>(
      future: _preview,
      builder: (context, snap) {
        if (snap.hasError) {
          return ErrorView(
            snap.error!,
            onRetry: () => setState(() => _preview = ref.read(apiProvider).previewInvite(widget.token)),
          );
        }
        final invite = snap.data;
        if (invite == null) return const Center(child: CircularProgressIndicator());
        return MessageView(
          icon: Icons.group,
          title: invite.alreadyMember ? 'Você já está em "${invite.spaceName}"' : invite.spaceName,
          message: invite.alreadyMember
              ? null
              : '${invite.inviter ?? 'Alguém'} convidou você para este grupo '
                  '(${invite.members} pessoa${invite.members == 1 ? '' : 's'}).',
          action: invite.alreadyMember ? null : (_busy ? 'Entrando…' : 'Entrar no grupo'),
          onAction: _busy || invite.alreadyMember ? null : _accept,
        );
      },
    ),
  );
}
