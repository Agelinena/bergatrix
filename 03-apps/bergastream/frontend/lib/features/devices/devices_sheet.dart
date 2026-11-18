import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/berga_colors.dart';
import '../../core/theme/berga_sizes.dart';
import '../../core/theme/berga_text.dart';
import '../player/player_controller.dart';
import '../../core/widgets/widgets.dart';
import '../output/output_devices.dart';
import 'device_controller.dart';

/// Textos do "Tocar em…".
abstract final class DevicesTexts {
  static const title = 'Tocar em…';
  static const here = 'Este aparelho';
  static const playing = 'Tocando';
  static const alone =
      'Abra o Bergastream em outro aparelho com a mesma conta (celular, '
      'computador ou navegador) e ele aparece aqui.';
  static const offline = 'Sem conexão com o servidor.';
  static const network = 'Na rede';
  static const searching = 'Procurando Chromecast e TVs…';
  static const noneFound =
      'Nenhum Chromecast ou TV achado. Eles precisam estar ligados e na mesma '
      'rede Wi-Fi.';
  static const stopCasting = 'Parar de transmitir';

  /// "Tocando em Notebook"; numa sessão que toca só no aparelho de quem
  /// criou: "Tocando no aparelho de Lucas".
  static String playingOn(String name) =>
      name.startsWith(PlayerController.sessionOwnerPrefix)
      ? 'Tocando no $name'
      : 'Tocando em $name';
}

IconData deviceIcon(String platform) => switch (platform) {
  'web' => Icons.language,
  'android' || 'ios' => Icons.smartphone,
  _ => Icons.computer,
};

/// Botão "Tocar em…" (player grande e barra do computador). Verde quando
/// outro aparelho é o que toca.
class DevicesButton extends ConsumerWidget {
  const DevicesButton({super.key, this.iconSize = 24, this.idleColor});

  final double iconSize;
  final Color? idleColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = BergaColors.of(context);
    final elsewhere =
        ref.watch(devicesProvider.select((d) => d.otherActive != null)) ||
        ref.watch(playerProvider.select((s) => s.playingOn != null));
    return IconButton(
      onPressed: () => openDevicesSheet(context),
      icon: const Icon(Icons.speaker_group_outlined),
      iconSize: iconSize,
      color: elsewhere ? c.gr : (idleColor ?? c.tx),
      tooltip: DevicesTexts.title,
    );
  }
}

/// "Tocando em Chrome · Linux" (abaixo da música, quando toca em outro
/// aparelho). Tocar abre a lista.
class PlayingOnLabel extends StatelessWidget {
  const PlayingOnLabel({super.key, required this.name, this.compact = false});

  final String name;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = BergaColors.of(context);
    return GestureDetector(
      onTap: () => openDevicesSheet(context),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 4,
        children: [
          Icon(Icons.speaker_group, size: compact ? 13 : 16, color: c.gr),
          Flexible(
            child: Text(
              DevicesTexts.playingOn(name),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: BergaText.secondary.copyWith(
                color: c.gr,
                fontSize: compact ? 12 : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> openDevicesSheet(BuildContext context) {
  final c = BergaColors.of(context);
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    backgroundColor: c.bg,
    barrierColor: c.scrim,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(BergaSizes.cardRadius),
      ),
    ),
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (_) => const DevicesSheet(),
  );
}

/// Lista dos aparelhos da pessoa e, na rede, Chromecasts e TVs: tocar num
/// deles passa a música para lá.
class DevicesSheet extends ConsumerStatefulWidget {
  const DevicesSheet({super.key});

  @override
  ConsumerState<DevicesSheet> createState() => _DevicesSheetState();
}

class _DevicesSheetState extends ConsumerState<DevicesSheet> {
  @override
  void initState() {
    super.initState();
    // Procura Chromecasts e TVs ao abrir.
    Future.microtask(() {
      if (mounted) ref.read(outputDevicesProvider.notifier).search();
    });
  }

  Future<void> _cast(OutputDevice device) async {
    final navigator = Navigator.of(context);
    try {
      final renderer = await ref
          .read(outputDevicesProvider.notifier)
          .connect(device);
      await ref.read(playerProvider.notifier).switchOutput(renderer);
      if (navigator.mounted) navigator.pop();
    } on Object catch (e) {
      debugPrint('Tocar em ${device.name}: $e');
      if (mounted) {
        AppToast.show(context, 'Não deu para conectar em ${device.name}.');
      }
    }
  }

  Future<void> _stopCasting() async {
    await ref.read(playerProvider.notifier).switchOutput(null);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = BergaColors.of(context);
    final devices = ref.watch(devicesProvider);
    final network = ref.watch(outputDevicesProvider);
    final casting = ref.watch(playerProvider.notifier).renderer;
    ref.watch(playerProvider.select((s) => s.playingOn));
    final mu = BergaText.secondary.copyWith(color: c.mu);
    // Este aparelho primeiro; depois o que toca; depois os outros.
    final list = [...devices.devices]
      ..sort((a, b) {
        int rank(DeviceInfo d) => d.id == devices.myId
            ? 0
            : d.id == devices.activeId
            ? 1
            : 2;
        return rank(a).compareTo(rank(b));
      });
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(DevicesTexts.title, style: BergaText.h2.copyWith(color: c.tx)),
            const SizedBox(height: 8),
            if (!devices.connected)
              Text(DevicesTexts.offline, style: mu)
            else ...[
              for (final d in list)
                _DeviceRow(
                  device: d,
                  here: d.id == devices.myId,
                  playing: d.id == devices.activeId,
                  onTap: () {
                    // Transmitindo: "Este aparelho" traz a música de volta.
                    if (casting != null && d.id == devices.myId) {
                      _stopCasting();
                      return;
                    }
                    ref.read(devicesProvider.notifier).transfer(d.id);
                    Navigator.of(context).pop();
                  },
                ),
              if (list.length < 2) ...[
                const SizedBox(height: 8),
                Text(DevicesTexts.alone, style: mu),
              ],
            ],
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: Text(
                    DevicesTexts.network,
                    style: BergaText.trackTitle.copyWith(color: c.tx),
                  ),
                ),
                if (network.searching)
                  SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: c.mu,
                    ),
                  )
                else
                  IconButton(
                    tooltip: 'Procurar de novo',
                    onPressed: () =>
                        ref.read(outputDevicesProvider.notifier).search(),
                    icon: Icon(Icons.refresh, color: c.mu, size: 20),
                  ),
              ],
            ),
            if (casting != null)
              _NetworkRow(
                name: casting.name,
                kind: casting.kind,
                active: true,
                subtitle: DevicesTexts.stopCasting,
                onTap: _stopCasting,
              ),
            for (final d in network.devices)
              if (casting == null || d.name != casting.name)
                _NetworkRow(
                  name: d.name,
                  kind: d.kind,
                  busy: network.connecting == d.id,
                  onTap: network.connecting == null ? () => _cast(d) : null,
                ),
            if (network.searching && network.devices.isEmpty)
              Text(DevicesTexts.searching, style: mu)
            else if (!network.searching &&
                network.devices.isEmpty &&
                casting == null)
              Text(DevicesTexts.noneFound, style: mu),
          ],
        ),
      ),
    );
  }
}

/// Chromecast ou TV na rede.
class _NetworkRow extends StatelessWidget {
  const _NetworkRow({
    required this.name,
    required this.kind,
    required this.onTap,
    this.active = false,
    this.busy = false,
    this.subtitle,
  });

  final String name;
  final String kind;
  final bool active;
  final bool busy;
  final String? subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = BergaColors.of(context);
    final color = active ? c.gr : c.tx;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(BergaSizes.cardRadius),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Row(
          spacing: 14,
          children: [
            Icon(
              kind == 'DLNA' ? Icons.tv : Icons.cast,
              color: color,
              size: 26,
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: BergaText.trackTitle.copyWith(color: color),
                  ),
                  Text(
                    subtitle ?? kind,
                    style: BergaText.secondary.copyWith(
                      color: active ? c.gr : c.mu,
                    ),
                  ),
                ],
              ),
            ),
            if (busy)
              SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: c.mu),
              )
            else if (active)
              Icon(Icons.cast_connected, color: c.gr, size: 20),
          ],
        ),
      ),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    required this.device,
    required this.here,
    required this.playing,
    required this.onTap,
  });

  final DeviceInfo device;
  final bool here;
  final bool playing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = BergaColors.of(context);
    final color = playing ? c.gr : c.tx;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(BergaSizes.cardRadius),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Row(
          spacing: 14,
          children: [
            Icon(deviceIcon(device.platform), color: color, size: 26),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    here ? DevicesTexts.here : device.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: BergaText.trackTitle.copyWith(color: color),
                  ),
                  Text(
                    [
                      if (here) device.name,
                      if (playing) DevicesTexts.playing,
                    ].join(' · '),
                    style: BergaText.secondary.copyWith(
                      color: playing ? c.gr : c.mu,
                    ),
                  ),
                ],
              ),
            ),
            if (playing) Icon(Icons.volume_up, color: c.gr, size: 20),
          ],
        ),
      ),
    );
  }
}
