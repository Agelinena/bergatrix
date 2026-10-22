import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/routes.dart';
import '../../core/network/api_error.dart';
import '../../core/theme/berga_colors.dart';
import '../../core/theme/berga_sizes.dart';
import '../../core/theme/berga_text.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/account.dart';
import '../../data/repositories/account_repository.dart';
import '../auth/session.dart';
import 'account_providers.dart';

/// Aviso antes de mexer em usuário/e-mail de uma conta que ainda não entrou
/// pelo Authentik: são eles que ligam as contas no 1º login.
const linkWarning =
    'Esta conta ainda não entrou pelo Authentik. No 1º login, as contas são '
    'ligadas pelo usuário ou pelo e-mail: deixe iguais aos do Authentik, '
    'senão pode ligar na conta errada ou criar outra.';

/// "Editar perfil" de quem ainda não entrou pelo Authentik: só o nome.
const selfLinkNote =
    'Enquanto sua conta não entrar pelo Authentik, usuário e e-mail só o '
    'administrador muda (são eles que ligam as contas no 1º login).';

/// Cartão "Conta" em Ajustes: nome, usuário e e-mail; editar, trocar senha
/// ou, se vêm do Authentik, abrir a página de lá. Admin: "Usuários".
class AccountCard extends ConsumerWidget {
  const AccountCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(myAccountProvider).value;
    if (account == null) return const SizedBox.shrink();
    final c = BergaColors.of(context);
    final mu = BergaText.secondary.copyWith(color: c.mu);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Conta', style: BergaText.trackTitle.copyWith(color: c.tx)),
          Text('${account.name} · ${account.username}', style: mu),
          Text(account.email ?? 'Sem e-mail', style: mu),
          if (account.managedByAuthentik)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Usuário, e-mail e senha vêm do Authentik.',
                style: mu,
              ),
            ),
          const SizedBox(height: 12),
          Wrap(
            spacing: BergaSizes.chipGap,
            runSpacing: 8,
            children: [
              if (account.managedByAuthentik && account.accountUrl != null)
                AppChip(
                  label: 'Gerenciar no Authentik',
                  icon: Icons.open_in_new,
                  onTap: () =>
                      ref.read(externalLinkProvider)(account.accountUrl!),
                )
              else if (!account.managedByAuthentik)
                AppChip(
                  label: 'Editar perfil',
                  onTap: () => _edit(context, ref, account),
                ),
              if (account.canChangePassword)
                AppChip(
                  label: 'Trocar senha',
                  onTap: () => _password(context, ref, account),
                ),
              if (account.isAdmin)
                AppChip(
                  label: 'Usuários',
                  icon: Icons.manage_accounts_outlined,
                  onTap: () => context.push(AppRoutes.adminUsers),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _edit(BuildContext context, WidgetRef ref, Account a) async {
    final onlyName = a.linkPending;
    final result = await showFormDialog(
      context,
      title: 'Editar perfil',
      note: onlyName ? selfLinkNote : null,
      fields: [
        FormFieldSpec('Nome', initial: a.name, maxLength: 60),
        if (!onlyName) ...[
          FormFieldSpec('Usuário', initial: a.username, maxLength: 32),
          FormFieldSpec(
            'E-mail',
            initial: a.email ?? '',
            keyboardType: TextInputType.emailAddress,
            required: false,
          ),
        ],
      ],
    );
    if (result == null || !context.mounted) return;
    final values = result.values;
    try {
      await ref
          .read(accountRepositoryProvider)
          .updateMyAccount(
            name: values[0],
            username: onlyName ? null : values[1],
            email: onlyName ? null : values[2],
          );
      // Usuário novo na sessão salva (e nos outros lugares do app).
      await ref.read(sessionProvider.notifier).validate();
      ref.invalidate(myAccountProvider);
      if (context.mounted) AppToast.show(context, 'Perfil salvo');
    } on ApiException catch (e) {
      if (context.mounted) AppToast.show(context, e.serverMessage);
    }
  }

  Future<void> _password(BuildContext context, WidgetRef ref, Account a) async {
    final result = await showFormDialog(
      context,
      title: 'Trocar senha',
      note: 'Os outros aparelhos conectados vão precisar entrar de novo.',
      fields: [
        if (a.hasPassword) const FormFieldSpec('Senha atual', obscure: true),
        const FormFieldSpec('Senha nova', obscure: true),
        const FormFieldSpec('Repita a senha nova', obscure: true),
      ],
      validate: (v) {
        final [..., next, again] = v;
        if (next.length < 8) {
          return 'A senha precisa ter pelo menos 8 caracteres.';
        }
        return next == again ? null : 'As senhas novas não conferem.';
      },
    );
    if (result == null || !context.mounted) return;
    final values = result.values;
    try {
      final tokens = await ref
          .read(accountRepositoryProvider)
          .changeMyPassword(
            current: a.hasPassword ? values.first : '',
            next: values[values.length - 2],
          );
      await ref.read(sessionProvider.notifier).replaceTokens(tokens);
      ref.invalidate(myAccountProvider);
      if (context.mounted) AppToast.show(context, 'Senha trocada');
    } on ApiException catch (e) {
      if (context.mounted) AppToast.show(context, e.serverMessage);
    }
  }
}
