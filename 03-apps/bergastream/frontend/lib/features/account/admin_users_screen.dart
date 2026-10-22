import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/routes.dart';
import '../../core/network/api_error.dart';
import '../../core/platform/app_layout.dart';
import '../../core/theme/berga_colors.dart';
import '../../core/theme/berga_sizes.dart';
import '../../core/theme/berga_text.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/account.dart';
import '../../data/repositories/account_repository.dart';
import 'account_card.dart';
import 'account_providers.dart';

/// "Usuários" (só admin): criar contas, editar, admin, senha, sessões,
/// ligação com o Authentik, avisos por e-mail e desativar.
///
/// Com o Authentik ligado, conta já ligada tem usuário, nome, e-mail e senha
/// só leitura aqui (vêm de lá a cada login); conta ainda não ligada mostra o
/// aviso antes de mudar usuário ou e-mail, que são o que liga as contas.
class AdminUsersScreen extends ConsumerWidget {
  const AdminUsersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = BergaColors.of(context);
    final mu = BergaText.secondary.copyWith(color: c.mu);
    final async = ref.watch(usersPageProvider);
    final page = async.value;
    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          color: c.gr,
          onRefresh: () => ref.refresh(usersPageProvider.future),
          child: ListView(
            padding: AppLayout.screenPadding(context),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: GestureDetector(
                  onTap: () => context.canPop()
                      ? context.pop()
                      : context.go(AppRoutes.settings),
                  child: Text('‹ Ajustes', style: mu),
                ),
              ),
              const SizedBox(height: 10),
              const ScreenTitle('Usuários', bottom: 4),
              if (async.hasError && page == null)
                Text(
                  async.error is ApiException
                      ? (async.error! as ApiException).serverMessage
                      : 'Não foi possível carregar os usuários.',
                  style: mu,
                ),
              if (page == null && !async.hasError)
                Text('Carregando…', style: mu),
              if (page != null) ...[
                Text(
                  '${page.users.length} '
                  '${page.users.length == 1 ? 'conta' : 'contas'}',
                  style: mu,
                ),
                _ServerCard(page: page),
                const SizedBox(height: 14),
                Align(
                  alignment: Alignment.centerLeft,
                  child: PrimaryButton(
                    label: 'Novo usuário',
                    icon: Icons.person_add_alt,
                    onPressed: () => _create(context, ref, page),
                  ),
                ),
                const SizedBox(height: 6),
                for (final user in page.users) _UserRow(user: user, page: page),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _create(
    BuildContext context,
    WidgetRef ref,
    UsersPage page,
  ) async {
    final result = await showFormDialog(
      context,
      title: 'Novo usuário',
      confirmLabel: 'Criar',
      note: page.oidcEnabled
          ? 'A pessoa entra pelo Authentik: no 1º login a conta é ligada pelo '
                'mesmo usuário ou e-mail de lá. Use os mesmos.'
          : null,
      fields: const [
        FormFieldSpec('Usuário', hint: 'ana', maxLength: 32),
        FormFieldSpec('Nome', hint: 'Ana Souza', maxLength: 60),
        FormFieldSpec(
          'E-mail',
          hint: 'ana@example.com',
          keyboardType: TextInputType.emailAddress,
          required: false,
        ),
      ],
      checkbox: page.mailEnabled ? 'Mandar convite por e-mail' : null,
    );
    if (result == null || !context.mounted) return;
    final [username, name, email] = result.values;
    await _run(context, ref, () async {
      await ref
          .read(accountRepositoryProvider)
          .createUser(
            username: username,
            name: name,
            email: email.isEmpty ? null : email,
            invite: result.checked,
          );
      return result.checked && email.isNotEmpty
          ? 'Conta criada e convite enviado'
          : 'Conta criada';
    });
  }
}

/// Faz a ação, mostra o resultado (ou o motivo do servidor) e recarrega.
Future<void> _run(
  BuildContext context,
  WidgetRef ref,
  Future<String?> Function() action,
) async {
  try {
    final done = await action();
    ref.invalidate(usersPageProvider);
    ref.invalidate(myAccountProvider);
    if (done != null && context.mounted) AppToast.show(context, done);
  } on ApiException catch (e) {
    if (context.mounted) AppToast.show(context, e.serverMessage);
  }
}

class _ServerCard extends ConsumerWidget {
  const _ServerCard({required this.page});

  final UsersPage page;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = BergaColors.of(context);
    final mu = BergaText.secondary.copyWith(color: c.mu);
    final label = BergaText.body.copyWith(fontSize: 14, color: c.tx);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 4,
        children: [
          Text(
            'E-mail: ${page.mailEnabled ? 'ligado' : 'não configurado'}',
            style: label,
          ),
          if (!page.mailEnabled)
            Text('Configure SMTP_* no .env do servidor.', style: mu),
          Text(
            'Authentik: ${page.oidcEnabled ? 'ligado' : 'desligado'}'
            '${page.passwordLoginEnabled ? ' · senha do Bergastream ligada' : ''}',
            style: label,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: BergaSizes.chipGap,
            runSpacing: 8,
            children: [
              if (page.mailEnabled)
                AppChip(
                  label: 'Testar e-mail',
                  icon: Icons.mark_email_read_outlined,
                  onTap: () => _run(context, ref, () async {
                    await ref.read(accountRepositoryProvider).testMail();
                    return 'E-mail de teste enviado para você';
                  }),
                ),
              if (page.authentikAdminUrl case final url?)
                AppChip(
                  label: 'Abrir no Authentik',
                  icon: Icons.open_in_new,
                  onTap: () => ref.read(externalLinkProvider)(url),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _UserRow extends ConsumerWidget {
  const _UserRow({required this.user, required this.page});

  final Account user;
  final UsersPage page;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = BergaColors.of(context);
    final mu = BergaText.secondary.copyWith(color: c.mu);
    final tags = [
      if (user.isAdmin) 'admin',
      if (user.linked) 'Authentik' else if (page.oidcEnabled) 'não ligada',
      if (user.disabled) 'desativada',
      if (user.sessions > 0)
        user.sessions == 1 ? '1 aparelho' : '${user.sessions} aparelhos',
    ];
    return InkWell(
      onTap: () => _actions(context, ref),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          spacing: 12,
          children: [
            Cover(seed: user.id, title: user.name, size: 44, circle: true),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    user.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: BergaText.trackTitle.copyWith(
                      color: user.disabled ? c.mu : c.tx,
                    ),
                  ),
                  Text(
                    '${user.username} · ${user.email ?? 'sem e-mail'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: mu,
                  ),
                  if (tags.isNotEmpty)
                    Text(tags.join(' · '), style: mu.copyWith(color: c.gr)),
                ],
              ),
            ),
            Icon(Icons.more_vert, color: c.mu),
          ],
        ),
      ),
    );
  }

  Future<void> _actions(BuildContext context, WidgetRef ref) async {
    final c = BergaColors.of(context);
    final canMail = page.mailEnabled && user.email != null;
    final canPassword = page.passwordLoginEnabled && !user.managedByAuthentik;
    final action = await showModalBottomSheet<Future<void> Function()>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: c.card,
      barrierColor: c.scrim,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(BergaSizes.sheetRadius),
        ),
      ),
      builder: (sheet) {
        Widget item(
          IconData icon,
          String label,
          Future<void> Function()? run, {
          String? detail,
        }) => ListTile(
          leading: Icon(icon, color: run == null ? c.mu : c.tx),
          title: Text(
            label,
            style: BergaText.body.copyWith(color: run == null ? c.mu : c.tx),
          ),
          subtitle: detail == null
              ? null
              : Text(detail, style: BergaText.secondary.copyWith(color: c.mu)),
          onTap: run == null ? null : () => Navigator.of(sheet).pop(run),
        );
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    user.name,
                    style: BergaText.trackTitle.copyWith(color: c.tx),
                  ),
                ),
                item(
                  Icons.edit_outlined,
                  'Editar nome, usuário e e-mail',
                  user.managedByAuthentik ? null : () => _edit(context, ref),
                  detail: user.managedByAuthentik
                      ? 'Vêm do Authentik: altere lá'
                      : null,
                ),
                item(
                  Icons.admin_panel_settings_outlined,
                  user.isAdmin ? 'Tirar admin' : 'Tornar admin',
                  user.adminManagedByAuthentik
                      ? null
                      : () => _patch(
                          context,
                          ref,
                          isAdmin: !user.isAdmin,
                          done: user.isAdmin
                              ? 'Não é mais admin'
                              : 'Agora é admin',
                        ),
                  detail: user.adminManagedByAuthentik
                      ? 'Vem do grupo de admins do Authentik'
                      : null,
                ),
                item(
                  Icons.password,
                  'Redefinir senha',
                  canPassword ? () => _password(context, ref, canMail) : null,
                  detail: user.managedByAuthentik
                      ? 'A senha é a do Authentik: redefina lá'
                      : !page.passwordLoginEnabled
                      ? 'Login por senha desligado'
                      : null,
                ),
                item(
                  Icons.mail_outline,
                  'Mandar aviso por e-mail',
                  canMail ? () => _notice(context, ref) : null,
                  detail: canMail
                      ? null
                      : user.email == null
                      ? 'Sem e-mail'
                      : 'E-mail não configurado no servidor',
                ),
                item(
                  Icons.devices_other,
                  'Desconectar os aparelhos',
                  user.sessions == 0 ? null : () => _revoke(context, ref),
                  detail: user.sessions == 0
                      ? 'Nenhum aparelho conectado'
                      : 'Pedem login de novo (em até 15 min)',
                ),
                if (user.linked)
                  item(
                    Icons.link_off,
                    'Desligar do Authentik',
                    () => _unlink(context, ref),
                    detail: 'Só se ligou na conta errada',
                  ),
                item(
                  user.disabled
                      ? Icons.person_outline
                      : Icons.person_off_outlined,
                  user.disabled ? 'Reativar conta' : 'Desativar conta',
                  () => _toggleDisabled(context, ref, canMail),
                  detail: user.disabled
                      ? null
                      : 'Playlists e histórico ficam guardados',
                ),
              ],
            ),
          ),
        );
      },
    );
    await action?.call();
  }

  AccountRepository _repo(WidgetRef ref) => ref.read(accountRepositoryProvider);

  Future<void> _patch(
    BuildContext context,
    WidgetRef ref, {
    bool? isAdmin,
    bool? disabled,
    bool notify = true,
    required String done,
  }) => _run(context, ref, () async {
    await _repo(
      ref,
    ).updateUser(user.id, isAdmin: isAdmin, disabled: disabled, notify: notify);
    return done;
  });

  Future<void> _edit(BuildContext context, WidgetRef ref) async {
    final result = await showFormDialog(
      context,
      title: 'Editar ${user.name}',
      note: page.oidcEnabled && !user.linked ? linkWarning : null,
      fields: [
        FormFieldSpec('Nome', initial: user.name, maxLength: 60),
        FormFieldSpec('Usuário', initial: user.username, maxLength: 32),
        FormFieldSpec(
          'E-mail',
          initial: user.email ?? '',
          keyboardType: TextInputType.emailAddress,
          required: false,
        ),
      ],
      checkbox: page.mailEnabled ? 'Avisar a pessoa por e-mail' : null,
    );
    if (result == null || !context.mounted) return;
    final [name, username, email] = result.values;
    await _run(context, ref, () async {
      await _repo(ref).updateUser(
        user.id,
        name: name,
        username: username,
        email: email,
        notify: result.checked,
      );
      return 'Salvo';
    });
  }

  Future<void> _password(
    BuildContext context,
    WidgetRef ref,
    bool canMail,
  ) async {
    final options = [
      'Cancelar',
      if (canMail) 'Enviar link por e-mail',
      'Gerar senha temporária',
    ];
    final choice = await showChoiceDialog(
      context,
      message: 'Redefinir a senha de ${user.name}?',
      detail: canMail
          ? 'O link deixa a pessoa criar a senha nova sozinha. A senha '
                'temporária você passa para ela. Nos dois casos, os aparelhos '
                'conectados pedem login de novo.'
          : 'Você passa a senha temporária para a pessoa. Os aparelhos '
                'conectados pedem login de novo.',
      options: options,
    );
    if (choice == null || choice == 0 || !context.mounted) return;
    final link = options[choice] == 'Enviar link por e-mail';
    PasswordReset? reset;
    await _run(context, ref, () async {
      reset = await _repo(ref).resetPassword(user.id, link: link);
      return link ? 'Link enviado para ${user.email}' : null;
    });
    final password = reset?.password;
    if (password == null || !context.mounted) return;
    await _showPassword(context, password, sent: reset!.sent);
  }

  Future<void> _showPassword(
    BuildContext context,
    String password, {
    required bool sent,
  }) => showDialog<void>(
    context: context,
    builder: (dialog) {
      final c = BergaColors.of(dialog);
      return AlertDialog(
        backgroundColor: c.card,
        title: Text(
          'Senha temporária',
          style: BergaText.trackTitle.copyWith(color: c.tx),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 10,
          children: [
            SelectableText(
              password,
              style: BergaText.h1.copyWith(color: c.tx, fontSize: 24),
            ),
            Text(
              'Passe para ${user.name} por um canal seguro; ela não aparece '
              'de novo. ${sent ? 'A pessoa recebeu um e-mail avisando (sem a senha).' : ''}',
              style: BergaText.secondary.copyWith(color: c.mu),
            ),
          ],
        ),
        actions: [
          AppChip(
            label: 'Copiar',
            icon: Icons.copy,
            onTap: () async {
              await Clipboard.setData(ClipboardData(text: password));
              if (dialog.mounted) AppToast.show(dialog, 'Senha copiada');
            },
          ),
          AppChip(
            label: 'Fechar',
            active: true,
            onTap: () => Navigator.of(dialog).pop(),
          ),
        ],
      );
    },
  );

  Future<void> _notice(BuildContext context, WidgetRef ref) async {
    final result = await showFormDialog(
      context,
      title: 'Aviso para ${user.name}',
      confirmLabel: 'Enviar',
      fields: const [
        FormFieldSpec('Assunto', maxLength: 120),
        FormFieldSpec('Mensagem', maxLength: 4000, maxLines: 6),
      ],
    );
    if (result == null || !context.mounted) return;
    final [subject, message] = result.values;
    await _run(context, ref, () async {
      await _repo(ref).sendNotice(user.id, subject: subject, message: message);
      return 'Aviso enviado para ${user.email}';
    });
  }

  Future<void> _revoke(BuildContext context, WidgetRef ref) async {
    final choice = await showChoiceDialog(
      context,
      message: 'Desconectar os aparelhos de ${user.name}?',
      detail: 'Eles pedem login de novo (em até 15 min).',
      options: const ['Cancelar', 'Desconectar'],
    );
    if (choice != 1 || !context.mounted) return;
    await _run(context, ref, () async {
      await _repo(ref).revokeSessions(user.id);
      return 'Aparelhos desconectados';
    });
  }

  Future<void> _unlink(BuildContext context, WidgetRef ref) async {
    final choice = await showChoiceDialog(
      context,
      message: 'Desligar ${user.name} do Authentik?',
      detail:
          'Use só se a conta foi ligada à pessoa errada. Os aparelhos '
          'desconectam e o próximo login pelo Authentik liga de novo pelo '
          'usuário ou e-mail; confira esses dois antes.',
      options: const ['Cancelar', 'Desligar'],
    );
    if (choice != 1 || !context.mounted) return;
    await _run(context, ref, () async {
      await _repo(ref).unlink(user.id);
      return 'Desligada do Authentik';
    });
  }

  Future<void> _toggleDisabled(
    BuildContext context,
    WidgetRef ref,
    bool canMail,
  ) async {
    final disable = !user.disabled;
    final choice = await showChoiceDialog(
      context,
      message: disable
          ? 'Desativar a conta de ${user.name}?'
          : 'Reativar a conta de ${user.name}?',
      detail: disable
          ? 'A pessoa não entra mais (nem pelo Authentik) e os aparelhos '
                'desconectam. Playlists e histórico ficam guardados.'
          : null,
      options: [
        'Cancelar',
        if (canMail) disable ? 'Desativar sem avisar' : 'Reativar sem avisar',
        disable
            ? (canMail ? 'Desativar e avisar' : 'Desativar')
            : (canMail ? 'Reativar e avisar' : 'Reativar'),
      ],
    );
    if (choice == null || choice == 0 || !context.mounted) return;
    final notify = canMail && choice == 2;
    await _patch(
      context,
      ref,
      disabled: disable,
      notify: notify,
      done: disable ? 'Conta desativada' : 'Conta reativada',
    );
  }
}
