import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/router.dart';
import '../../core/network/api_error.dart';
import '../../core/theme/berga_colors.dart';
import '../../core/theme/berga_sizes.dart';
import '../../core/theme/berga_text.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/playlist_models.dart';
import '../../data/repositories/playlist_repository.dart';
import '../../data/repositories/session_repository.dart';
import '../auth/session.dart';
import 'group_session.dart';

/// Textos da sessão compartilhada.
abstract final class SessionTexts {
  static const title = 'Ouvir junto';
  static const intro =
      'Todo mundo na sessão ouve a mesma música, no mesmo ponto. Qualquer '
      'pessoa pode pôr músicas na fila, pular e voltar.';
  static const seed = 'O que está tocando agora entra na sessão.';
  static const create = 'Criar sessão';
  static const invite = 'Convidar';
  static const leave = 'Sair da sessão';
  static const end = 'Encerrar para todos';
  static const pauseTitle = 'Modo de pausa';

  static String pauseDetail(PauseMode mode) => switch (mode) {
    PauseMode.all => 'Quem pausa, pausa para todo mundo.',
    PauseMode.individual =>
      'Pausar não afeta os outros; ao voltar, você entra no ponto em que '
          'eles estão.',
  };
}

/// Botão "Ouvir junto" (player grande e barra do computador). Verde quando
/// está numa sessão.
class SessionButton extends ConsumerWidget {
  const SessionButton({super.key, this.iconSize = 24, this.idleColor});

  final double iconSize;
  final Color? idleColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = BergaColors.of(context);
    final active = ref.watch(groupSessionProvider.select((s) => s.active));
    return IconButton(
      onPressed: () => openSessionSheet(context),
      icon: Icon(active ? Icons.groups : Icons.groups_outlined),
      iconSize: iconSize,
      color: active ? c.gr : (idleColor ?? c.tx),
      tooltip: SessionTexts.title,
    );
  }
}

Future<void> openSessionSheet(BuildContext context) {
  final c = BergaColors.of(context);
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: c.bg,
    barrierColor: c.scrim,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(BergaSizes.cardRadius),
      ),
    ),
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (_) => const SessionSheet(),
  );
}

/// Criar a sessão (fora de uma) ou ver pessoas e configurações (dentro).
class SessionSheet extends ConsumerStatefulWidget {
  const SessionSheet({super.key});

  @override
  ConsumerState<SessionSheet> createState() => _SessionSheetState();
}

class _SessionSheetState extends ConsumerState<SessionSheet> {
  final _name = TextEditingController();
  var _mode = PauseMode.all;
  var _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  GroupSessionController get _group => ref.read(groupSessionProvider.notifier);

  /// Roda [action] mostrando o erro do servidor, se houver.
  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } on ApiException catch (e) {
      if (mounted) AppToast.show(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final group = ref.watch(groupSessionProvider);
    final canUseServer = ref.watch(
      sessionProvider.select((s) => s.canUseServer),
    );
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.85,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
            child: !canUseServer && !group.active
                ? _Offline()
                : group.info == null
                ? _create(group)
                : _session(group, group.info!),
          ),
        ),
      ),
    );
  }

  Widget _create(GroupState group) {
    final c = BergaColors.of(context);
    final mu = BergaText.secondary.copyWith(color: c.mu);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(SessionTexts.title, style: BergaText.h2.copyWith(color: c.tx)),
        const SizedBox(height: 6),
        Text(SessionTexts.intro, style: mu),
        for (final invite in group.invites) ...[
          const SizedBox(height: 14),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  invite.name.isNotEmpty
                      ? invite.name
                      : 'Sessão de ${invite.owner.name}',
                  style: BergaText.trackTitle.copyWith(color: c.tx),
                ),
                Text(
                  'Convite de ${(invite.invitedBy ?? invite.owner).name}',
                  style: mu,
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: BergaSizes.chipGap,
                  children: [
                    AppChip(
                      label: 'Recusar',
                      onTap: () => _run(() => _group.decline(invite.sessionId)),
                    ),
                    AppChip(
                      label: 'Entrar',
                      active: true,
                      onTap: () => _run(() => _group.join(invite.sessionId)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 18),
        AppTextField(
          hint: 'Nome da sessão (opcional)',
          controller: _name,
          textInputAction: TextInputAction.done,
        ),
        const SizedBox(height: 18),
        Text(
          SessionTexts.pauseTitle,
          style: BergaText.trackTitle.copyWith(color: c.tx),
        ),
        const SizedBox(height: 8),
        _PauseModePicker(
          value: _mode,
          onChanged: (mode) => setState(() => _mode = mode),
        ),
        const SizedBox(height: 14),
        Text(SessionTexts.seed, style: mu),
        const SizedBox(height: 14),
        PrimaryButton(
          label: SessionTexts.create,
          icon: Icons.groups,
          expanded: true,
          onPressed: _busy
              ? null
              : () => _run(
                  () => _group.create(name: _name.text.trim(), mode: _mode),
                ),
        ),
      ],
    );
  }

  Widget _session(GroupState group, SessionInfo info) {
    final c = BergaColors.of(context);
    final mu = BergaText.secondary.copyWith(color: c.mu);
    final me = ref.watch(sessionProvider.select((s) => s.username));
    final isOwner = info.owner.username == me;
    final people = [
      for (final m in info.members)
        if (m.joined || m.status == 'invited') m,
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(info.title, style: BergaText.h2.copyWith(color: c.tx)),
        const SizedBox(height: 4),
        Text(
          group.connected ? 'Ouvindo junto' : 'Reconectando…',
          style: mu.copyWith(color: group.connected ? c.gr : c.mu),
        ),
        const SizedBox(height: 18),
        Text(
          SessionTexts.pauseTitle,
          style: BergaText.trackTitle.copyWith(color: c.tx),
        ),
        const SizedBox(height: 8),
        if (isOwner)
          _PauseModePicker(
            value: info.pauseMode,
            onChanged: (mode) => _run(() => _group.setPauseMode(mode)),
          )
        else ...[
          Text(
            info.pauseMode.label,
            style: BergaText.body.copyWith(color: c.tx),
          ),
          Text(SessionTexts.pauseDetail(info.pauseMode), style: mu),
        ],
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(
              child: Text(
                'Pessoas',
                style: BergaText.trackTitle.copyWith(color: c.tx),
              ),
            ),
            AppChip(
              label: SessionTexts.invite,
              icon: Icons.person_add_alt,
              onTap: () => _invite(info, me),
            ),
          ],
        ),
        const SizedBox(height: 6),
        for (final m in people)
          _MemberRow(
            member: m,
            isOwner: m.user.id == info.owner.id,
            isMe: m.user.username == me,
            onRemove: isOwner && m.user.username != me
                ? () => _run(() => _group.kick(m.user.id))
                : null,
          ),
        const SizedBox(height: 18),
        Align(
          alignment: Alignment.centerRight,
          child: AppChip(
            label: isOwner ? SessionTexts.end : SessionTexts.leave,
            icon: isOwner ? Icons.stop_circle_outlined : Icons.logout,
            onTap: () => _run(() async {
              if (isOwner) {
                final ok = await showChoiceDialog(
                  context,
                  message: 'Encerrar a sessão para todos?',
                  options: const ['Cancelar', 'Encerrar'],
                );
                if (ok != 1) return;
                await _group.end();
              } else {
                await _group.leave();
              }
              if (mounted) Navigator.of(context).pop();
            }),
          ),
        ),
      ],
    );
  }

  Future<void> _invite(SessionInfo info, String? me) async {
    final List<Person> people;
    try {
      people = await ref.read(playlistRepositoryProvider).directory();
    } on ApiException catch (e) {
      if (mounted) AppToast.show(context, e.message);
      return;
    }
    final inSession = {
      for (final m in info.members)
        if (m.joined) m.user.id,
    };
    final invited = {
      for (final m in info.members)
        if (m.status == 'invited') m.user.id,
    };
    final candidates = [
      for (final p in people)
        if (p.username != me && !inSession.contains(p.id)) p,
    ];
    if (!mounted) return;
    if (candidates.isEmpty) {
      AppToast.show(context, 'Todos os usuários já estão na sessão');
      return;
    }
    final chosen = await showDialog<List<String>>(
      context: context,
      barrierColor: BergaColors.of(context).scrim,
      builder: (_) => _InviteDialog(people: candidates, invited: invited),
    );
    if (chosen == null || chosen.isEmpty || !mounted) return;
    await _run(() async {
      await _group.invite(chosen);
      if (mounted) {
        AppToast.show(
          context,
          chosen.length == 1 ? 'Convite enviado' : 'Convites enviados',
        );
      }
    });
  }
}

class _Offline extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = BergaColors.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(SessionTexts.title, style: BergaText.h2.copyWith(color: c.tx)),
        const SizedBox(height: 6),
        Text(
          'Precisa do servidor: entre na sua conta e fique online para ouvir '
          'junto.',
          style: BergaText.secondary.copyWith(color: c.mu),
        ),
      ],
    );
  }
}

class _PauseModePicker extends StatelessWidget {
  const _PauseModePicker({required this.value, required this.onChanged});

  final PauseMode value;
  final ValueChanged<PauseMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = BergaColors.of(context);
    return Column(
      spacing: 8,
      children: [
        for (final mode in PauseMode.values)
          GestureDetector(
            onTap: () => onChanged(mode),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: c.card,
                borderRadius: BorderRadius.circular(BergaSizes.cardRadius),
                border: Border.all(
                  color: mode == value ? c.ac : Colors.transparent,
                  width: 1.5,
                ),
              ),
              child: Row(
                spacing: 10,
                children: [
                  Icon(
                    mode == value
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    color: mode == value ? c.ac : c.mu,
                    size: 20,
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          mode.label,
                          style: BergaText.trackTitle.copyWith(color: c.tx),
                        ),
                        Text(
                          SessionTexts.pauseDetail(mode),
                          style: BergaText.secondary.copyWith(color: c.mu),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({
    required this.member,
    required this.isOwner,
    required this.isMe,
    this.onRemove,
  });

  final SessionMember member;
  final bool isOwner;
  final bool isMe;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final c = BergaColors.of(context);
    final name = member.user.name.isNotEmpty
        ? member.user.name
        : member.user.username;
    final status = !member.joined
        ? 'Convidado'
        : member.online
        ? 'Online'
        : 'Fora do app';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        spacing: 12,
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: c.card,
            child: Text(
              name.characters.first.toUpperCase(),
              style: BergaText.trackTitle.copyWith(color: c.tx),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  [name, if (isMe) '(você)'].join(' '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: BergaText.trackTitle.copyWith(color: c.tx),
                ),
                Text(
                  [status, if (isOwner) 'criou a sessão'].join(' · '),
                  style: BergaText.secondary.copyWith(
                    color: member.joined && member.online ? c.gr : c.mu,
                  ),
                ),
              ],
            ),
          ),
          if (onRemove != null)
            IconButton(
              onPressed: onRemove,
              icon: const Icon(Icons.close),
              iconSize: 20,
              color: c.mu,
              tooltip: 'Remover da sessão',
            ),
        ],
      ),
    );
  }
}

class _InviteDialog extends StatefulWidget {
  const _InviteDialog({required this.people, required this.invited});

  final List<Person> people;
  final Set<String> invited;

  @override
  State<_InviteDialog> createState() => _InviteDialogState();
}

class _InviteDialogState extends State<_InviteDialog> {
  final _chosen = <String>{};

  @override
  Widget build(BuildContext context) {
    final c = BergaColors.of(context);
    return Dialog(
      backgroundColor: c.card,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(BergaSizes.cardRadius),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380, maxHeight: 520),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Convidar para ouvir junto',
                style: BergaText.trackTitle.copyWith(color: c.tx),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final p in widget.people)
                      CheckboxListTile(
                        value: _chosen.contains(p.id),
                        onChanged: (v) => setState(
                          () => v == true
                              ? _chosen.add(p.id)
                              : _chosen.remove(p.id),
                        ),
                        activeColor: c.ac,
                        checkColor: c.on,
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          p.name.isNotEmpty ? p.name : p.username,
                          style: BergaText.body.copyWith(color: c.tx),
                        ),
                        subtitle: widget.invited.contains(p.id)
                            ? Text(
                                'Já convidado (convidar de novo)',
                                style: BergaText.secondary.copyWith(
                                  color: c.mu,
                                ),
                              )
                            : null,
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: BergaSizes.chipGap,
                children: [
                  AppChip(
                    label: 'Cancelar',
                    onTap: () => Navigator.of(context).pop(),
                  ),
                  AppChip(
                    label: SessionTexts.invite,
                    active: true,
                    onTap: () => Navigator.of(context).pop(_chosen.toList()),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Mostra os convites para ouvir junto assim que chegam (uma vez cada).
class SessionInviteWatcher extends ConsumerStatefulWidget {
  const SessionInviteWatcher({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<SessionInviteWatcher> createState() =>
      _SessionInviteWatcherState();
}

class _SessionInviteWatcherState extends ConsumerState<SessionInviteWatcher> {
  final _shown = <String>{};

  Future<void> _offer(SessionInvite invite) async {
    // Este widget fica acima do Navigator: o diálogo usa o do router.
    final context = ref
        .read(routerProvider)
        .routerDelegate
        .navigatorKey
        .currentState
        ?.overlay
        ?.context;
    if (context == null || !context.mounted) return;
    final from = (invite.invitedBy ?? invite.owner).name;
    final choice = await showChoiceDialog(
      context,
      message: '$from te chamou para ouvir junto',
      detail:
          'Na sessão, todos ouvem a mesma música ao mesmo tempo. Entrar '
          'troca o que está tocando aqui.',
      options: const ['Agora não', 'Entrar'],
    );
    final group = ref.read(groupSessionProvider.notifier);
    try {
      switch (choice) {
        case 1:
          await group.join(invite.sessionId);
        case 0:
          await group.decline(invite.sessionId);
      }
    } on ApiException catch (e) {
      if (context.mounted) AppToast.show(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(groupSessionProvider.select((s) => s.invites), (_, invites) {
      for (final invite in invites) {
        if (_shown.add(invite.sessionId)) _offer(invite);
      }
    });
    return widget.child;
  }
}

/// Cartão em Ajustes: entrar na sessão sem precisar de música tocando.
class SessionSettingsCard extends ConsumerWidget {
  const SessionSettingsCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = BergaColors.of(context);
    final group = ref.watch(groupSessionProvider);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            SessionTexts.title,
            style: BergaText.trackTitle.copyWith(color: c.tx),
          ),
          Text(
            group.info != null
                ? 'Na ${group.info!.title}'
                : group.invites.isNotEmpty
                ? '${group.invites.length} convite(s) pendente(s)'
                : 'Ouça a mesma música com outras pessoas do servidor',
            style: BergaText.secondary.copyWith(color: c.mu),
          ),
          const SizedBox(height: 12),
          AppChip(
            label: group.info != null ? 'Ver sessão' : SessionTexts.title,
            icon: Icons.groups,
            onTap: () => openSessionSheet(context),
          ),
        ],
      ),
    );
  }
}
