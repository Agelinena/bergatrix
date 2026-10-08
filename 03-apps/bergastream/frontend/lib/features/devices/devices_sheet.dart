import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/berga_colors.dart';
import '../../core/theme/berga_sizes.dart';
import '../../core/theme/berga_text.dart';
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

  static String playingOn(String name) => 'Tocando em $name';
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
    final elsewhere = ref.watch(
      devicesProvider.select((d) => d.otherActive != null),
    );
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

/// Lista dos aparelhos da pessoa: tocar num deles passa a música para lá.
class DevicesSheet extends ConsumerWidget {
  const DevicesSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = BergaColors.of(context);
    final devices = ref.watch(devicesProvider);
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
                    ref.read(devicesProvider.notifier).transfer(d.id);
                    Navigator.of(context).pop();
                  },
                ),
              if (list.length < 2) ...[
                const SizedBox(height: 8),
                Text(DevicesTexts.alone, style: mu),
              ],
            ],
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
