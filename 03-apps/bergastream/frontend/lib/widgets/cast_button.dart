import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/theme/app_theme.dart';
import '../core/api_client.dart';
import '../providers/cast_provider.dart';
import '../providers/player_provider.dart';
import '../services/cast/cast_service.dart';

/// Botão de transmissão (Chromecast) para a barra do player.
///
/// – Na web: exibe dica para usar o botão nativo do Chrome.
/// – No nativo (Android/Linux/Windows): abre o painel de descoberta.
class CastButton extends ConsumerWidget {
  const CastButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cast = ref.watch(castProvider);

    if (cast.isBusy) {
      return const SizedBox(
        width: 36, height: 36,
        child: Center(
          child: SizedBox(
            width: 18, height: 18,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: AppColors.primary),
          ),
        ),
      );
    }

    return IconButton(
      icon: Icon(
        Icons.cast,
        size: 20,
        color: cast.isActive ? AppColors.primary : AppColors.textSecondary,
      ),
      tooltip: cast.isActive
          ? 'Transmitindo para ${cast.activeDevice?.name}'
          : 'Transmitir para TV (Chromecast)',
      onPressed: () => _onPressed(context, ref, cast),
    );
  }

  void _onPressed(BuildContext ctx, WidgetRef ref, CastState cast) {
    if (kIsWeb) {
      _showWebDialog(ctx);
      return;
    }
    if (cast.isActive) {
      _showActiveDialog(ctx, ref, cast);
    } else {
      _showDiscoverySheet(ctx, ref: ref);
    }
  }

  // ── Web: instrução de uso do cast nativo do Chrome ─────────────────────

  void _showWebDialog(BuildContext ctx) {
    showDialog(
      context: ctx,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surfaceVariant,
        title: const Row(children: [
          Icon(Icons.cast, color: AppColors.primary),
          SizedBox(width: 10),
          Text('Transmitir no Chrome'),
        ]),
        content: const Text(
          'No Chrome, clique no ícone de transmissão (⋮ → Transmitir…) '
          'ou use o atalho de menu do sistema operacional.\n\n'
          'A URL da faixa será reproduzida automaticamente pelo receptor padrão do Chromecast.',
          style: TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Entendido'),
          ),
        ],
      ),
    );
  }

  // ── Nativo: já conectado ───────────────────────────────────────────────

  void _showActiveDialog(BuildContext ctx, WidgetRef ref, CastState cast) {
    showDialog(
      context: ctx,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surfaceVariant,
        title: Row(children: [
          const Icon(Icons.cast_connected, color: AppColors.primary),
          const SizedBox(width: 10),
          Text(cast.activeDevice?.name ?? 'Dispositivo'),
        ]),
        content: const Text('Transmissão ativa.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () {
              Navigator.pop(ctx);
              ref.read(castProvider.notifier).disconnect();
            },
            child: const Text('Encerrar transmissão'),
          ),
        ],
      ),
    );
  }

  // ── Nativo: descoberta ─────────────────────────────────────────────────

  void _showDiscoverySheet(BuildContext ctx, {required WidgetRef ref}) {
    // Inicia a descoberta imediatamente
    ref.read(castProvider.notifier).discover();

    showModalBottomSheet(
      context: ctx,
      backgroundColor: AppColors.surfaceVariant,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => const _CastDiscoverySheet(),
    );
  }
}

// ── Discovery Bottom Sheet ─────────────────────────────────────────────────

class _CastDiscoverySheet extends ConsumerWidget {
  const _CastDiscoverySheet();

  @override
  Widget build(BuildContext context, WidgetRef innerRef) {
    final cast = innerRef.watch(castProvider);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(children: [
            const Icon(Icons.cast, color: AppColors.primary),
            const SizedBox(width: 10),
            Text('Transmitir para…',
                style: Theme.of(context).textTheme.titleMedium),
            const Spacer(),
            if (cast.status == CastStatus.discovering)
              const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: AppColors.primary))
            else
              IconButton(
                icon: const Icon(Icons.refresh, size: 20),
                onPressed: () => innerRef.read(castProvider.notifier).discover(),
                tooltip: 'Buscar novamente',
              ),
          ]),
          const SizedBox(height: 8),

          // Error
          if (cast.status == CastStatus.error && cast.errorMessage != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(cast.errorMessage!,
                  style: const TextStyle(color: AppColors.error, fontSize: 13)),
            ),

          // Device list
          if (cast.devices.isEmpty && cast.status != CastStatus.discovering)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.cast, size: 40, color: AppColors.textSecondary),
                  SizedBox(height: 12),
                  Text('Nenhum dispositivo encontrado na rede',
                      style: TextStyle(color: AppColors.textSecondary)),
                  SizedBox(height: 4),
                  Text(
                    'Verifique se o Chromecast está ligado e na mesma rede Wi-Fi.',
                    style:
                        TextStyle(color: AppColors.textSecondary, fontSize: 12),
                    textAlign: TextAlign.center,
                  ),
                ]),
              ),
            )
          else
            ...cast.devices.map(
              (device) => ListTile(
                leading: const Icon(Icons.cast, color: AppColors.textSecondary),
                title: Text(device.name),
                subtitle: Text(device.host,
                    style: const TextStyle(
                        color: AppColors.textSecondary, fontSize: 12)),
                onTap: () {
                  Navigator.pop(context);
                  innerRef.read(castProvider.notifier).castTo(device);
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text('Conectando a ${device.name}…'),
                    duration: const Duration(seconds: 2),
                  ));
                },
              ),
            ),

          // Copy stream URL fallback
          const Divider(height: 24),
          const _CopyUrlTile(),
        ],
      ),
    );
  }
}

// ── "Copiar URL" fallback (sem Chromecast) ─────────────────────────────────

class _CopyUrlTile extends ConsumerWidget {
  const _CopyUrlTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.link, color: AppColors.textSecondary, size: 20),
      title: const Text('Copiar URL da faixa', style: TextStyle(fontSize: 14)),
      subtitle: const Text(
        'Cole em qualquer player de rede (VLC, IINA…)',
        style: TextStyle(color: AppColors.textSecondary, fontSize: 11),
      ),
      onTap: () async {
        final apiClient = ref.read(apiClientProvider);
        final trackId   = ref.read(playerProvider).currentTrack?.id;
        if (trackId == null) {
          Navigator.pop(context);
          return;
        }
        final token = await apiClient.getToken();
        final url   = apiClient.streamUrl(trackId, token: token);
        await Clipboard.setData(ClipboardData(text: url));
        if (context.mounted) {
          Navigator.pop(context);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('URL copiada para a área de transferência'),
              duration: Duration(seconds: 2),
            ),
          );
        }
      },
    );
  }
}
