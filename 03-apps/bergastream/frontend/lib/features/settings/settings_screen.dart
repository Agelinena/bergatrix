import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/routes.dart';
import '../../core/platform/app_layout.dart';
import '../../core/platform/app_platform.dart';
import '../../core/theme/berga_colors.dart';
import '../../core/theme/berga_sizes.dart';
import '../../core/theme/berga_text.dart';
import '../../core/widgets/widgets.dart';
import '../../core/utils/format.dart';
import '../../data/local/database.dart';
import '../auth/session.dart';
import '../downloads/download_manager.dart';
import '../downloads/manage_downloads_screen.dart';
import '../playlists/playlist_store.dart';
import '../update/update_prompt.dart';
import '../update/update_service.dart';
import 'preferences.dart';

/// Aba Ajustes (Seção 6.5). Downloads e opções completas entram no
/// Passo 10; o cartão "Desenvolvimento" só existe em debug.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  Future<void> _logout(BuildContext context, WidgetRef ref) async {
    if (ref.read(appPlatformProvider).isApp) {
      // Alterações de playlist feitas offline: tenta enviar antes de sair.
      // (A fila já está carregada: a tela observa o provider.)
      var pending = ref.read(pendingPlaylistOpsProvider).value?.length ?? 0;
      if (pending > 0) {
        await ref.read(playlistSyncProvider.notifier).flush();
        pending = ref.read(pendingPlaylistOpsProvider).value?.length ?? 0;
      }
      if (pending > 0) {
        if (!context.mounted) return;
        final leave = await showChoiceDialog(
          context,
          message: pending == 1
              ? '1 alteração de playlist ainda não foi enviada ao servidor '
                    'e será perdida ao sair.'
              : '$pending alterações de playlist ainda não foram enviadas ao '
                    'servidor e serão perdidas ao sair.',
          options: const ['Cancelar', 'Sair mesmo assim'],
        );
        if (leave != 1) return;
      }
      if (!context.mounted) return;
      final choice = await showChoiceDialog(
        context,
        message: 'Manter as músicas baixadas neste aparelho?',
        options: const ['Apagar tudo', 'Manter'],
      );
      if (choice == null) return;
      if (choice == 0) {
        await ref.read(downloadManagerProvider.notifier).removeAll();
      }
    }
    await ref.read(sessionProvider.notifier).logout();
    // A cópia das playlists e a fila são da conta: saem do aparelho junto.
    await ref.read(playlistCacheProvider)?.clearAll();
    ref.invalidate(serverPlaylistsProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = BergaColors.of(context);
    final session = ref.watch(sessionProvider);
    final prefs = ref.watch(preferencesProvider);
    // Mantém a fila de playlists carregada (aviso ao sair).
    ref.watch(pendingPlaylistOpsProvider);
    final downloadsAvailable = ref
        .read(downloadManagerProvider.notifier)
        .available;
    final title = BergaText.trackTitle.copyWith(color: c.tx);
    final mu = BergaText.secondary.copyWith(color: c.mu);
    final link = BergaText.body.copyWith(fontSize: 14, color: c.gr);

    return ListView(
      key: const PageStorageKey('settings'),
      padding: AppLayout.screenPadding(context),
      children: [
        // No protótipo as margens do h1 (14) e do cartão (10) colapsam em 14.
        const ScreenTitle(
          'Ajustes',
          bottom: BergaSizes.h1Bottom - BergaSizes.cardMarginTop,
        ),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Servidor', style: title),
              Text(session.server ?? 'Nenhum servidor configurado', style: mu),
              switch (session.status) {
                SessionStatus.logado => Text(
                  'Conectado como ${session.username}',
                  style: link,
                ),
                SessionStatus.sessaoExpirada => Text(
                  'Sessão expirada',
                  style: mu,
                ),
                _ => Text('Não conectado', style: mu),
              },
              const SizedBox(height: 12),
              if (session.isLoggedIn)
                AppChip(label: 'Sair', onTap: () => _logout(context, ref))
              else
                PrimaryButton(
                  label: 'Entrar',
                  onPressed: () => context.go(AppRoutes.login),
                ),
            ],
          ),
        ),
        if (downloadsAvailable) const _OfflineCard(),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Qualidade de streaming', style: title),
              Text(prefs.quality.label, style: mu),
              const SizedBox(height: 12),
              Wrap(
                spacing: BergaSizes.chipGap,
                runSpacing: 8,
                children: [
                  for (final q in StreamQuality.values)
                    AppChip(
                      label: q.label.split(' ').first,
                      active: prefs.quality == q,
                      onTap: () =>
                          ref.read(preferencesProvider.notifier).setQuality(q),
                    ),
                ],
              ),
            ],
          ),
        ),
        if (ref.watch(updateTargetProvider) != null) const _AboutCard(),
        if (kDebugMode) _DevCard(session: session),
      ],
    );
  }
}

/// Versão instalada e "Verificar atualizações" (Android, Windows, Linux).
class _AboutCard extends ConsumerStatefulWidget {
  const _AboutCard();

  @override
  ConsumerState<_AboutCard> createState() => _AboutCardState();
}

class _AboutCardState extends ConsumerState<_AboutCard> {
  late final _version = ref.read(updateRepositoryProvider).currentVersion();
  var _checking = false;

  Future<void> _check() async {
    setState(() => _checking = true);
    await checkForUpdatesManually(context, ref);
    if (mounted) setState(() => _checking = false);
  }

  @override
  Widget build(BuildContext context) {
    final c = BergaColors.of(context);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Sobre', style: BergaText.trackTitle.copyWith(color: c.tx)),
          FutureBuilder(
            future: _version,
            builder: (context, snapshot) => Text(
              snapshot.hasData ? 'Bergastream ${snapshot.data}' : 'Bergastream',
              style: BergaText.secondary.copyWith(color: c.mu),
            ),
          ),
          const SizedBox(height: 12),
          AppChip(
            label: _checking ? 'Verificando…' : 'Verificar atualizações',
            icon: Icons.system_update,
            onTap: _checking ? null : _check,
          ),
        ],
      ),
    );
  }
}

/// Simulações para testar os avisos sem servidor real (só em debug).
class _DevCard extends ConsumerWidget {
  const _DevCard({required this.session});

  final SessionState session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = BergaColors.of(context);
    final controller = ref.read(sessionProvider.notifier);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Desenvolvimento',
            style: BergaText.trackTitle.copyWith(color: c.tx),
          ),
          Text(
            'Versão web em / e simulação do Android em /?modo=android '
            '(servidor: o endereço desta página, com http://).',
            style: BergaText.secondary.copyWith(color: c.mu),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: BergaSizes.chipGap,
            runSpacing: 8,
            children: [
              AppChip(
                label: 'Simular servidor indisponível',
                active: !session.serverAvailable,
                onTap: () =>
                    controller.setServerAvailable(!session.serverAvailable),
              ),
              if (session.isLoggedIn)
                AppChip(
                  label: 'Simular sessão expirada',
                  onTap: controller.debugExpireSession,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Cartão "Offline" (Seção 6.5): músicas baixadas, espaço, gerenciar e
/// apagar; "Baixar só no Wi-Fi".
class _OfflineCard extends ConsumerStatefulWidget {
  const _OfflineCard();

  @override
  ConsumerState<_OfflineCard> createState() => _OfflineCardState();
}

class _OfflineCardState extends ConsumerState<_OfflineCard> {
  bool? _wifiOnly;

  @override
  void initState() {
    super.initState();
    ref.read(localDatabaseProvider)?.stateValue(wifiOnlyKey).then((v) {
      if (mounted) setState(() => _wifiOnly = v != 'false');
    });
  }

  Future<void> _toggleWifi() async {
    final value = !(_wifiOnly ?? true);
    setState(() => _wifiOnly = value);
    await ref.read(localDatabaseProvider)?.setStateValue(wifiOnlyKey, '$value');
    await ref.read(downloadManagerProvider.notifier).pump();
  }

  @override
  Widget build(BuildContext context) {
    final c = BergaColors.of(context);
    final (count, bytes) = ref.watch(downloadsSummaryProvider).value ?? (0, 0);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Offline', style: BergaText.trackTitle.copyWith(color: c.tx)),
          Text(
            'Músicas baixadas no aparelho: $count (${formatBytes(bytes)}). Sem '
            'servidor, a biblioteca local continua funcionando.',
            style: BergaText.secondary.copyWith(color: c.mu),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: BergaSizes.chipGap,
            runSpacing: 8,
            children: [
              AppChip(
                label: 'Gerenciar downloads',
                onTap: () => context.push(AppRoutes.manageDownloads),
              ),
              AppChip(
                label: 'Apagar todos os downloads',
                onTap: () => confirmRemoveAll(context, ref),
              ),
              AppChip(
                label: 'Baixar só no Wi-Fi',
                icon: Icons.wifi,
                active: _wifiOnly ?? true,
                onTap: _toggleWifi,
              ),
              AppChip(
                label: 'Baixar novas músicas das playlists automaticamente',
                icon: Icons.sync,
                active: ref.watch(preferencesProvider).autoDownloadNew,
                onTap: () => ref
                    .read(preferencesProvider.notifier)
                    .setAutoDownloadNew(
                      !ref.read(preferencesProvider).autoDownloadNew,
                    ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
