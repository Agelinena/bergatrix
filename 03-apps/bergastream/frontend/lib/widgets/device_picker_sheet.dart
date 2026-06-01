import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/theme/app_theme.dart';
import '../providers/sync_provider.dart';

/// Bottom sheet showing every device this user is currently logged in
/// from (web, Android, desktop) and offering to transfer playback.
/// The active device is highlighted; tapping any other transfers
/// playback to itself / that device.
class DevicePickerSheet extends ConsumerWidget {
  const DevicePickerSheet({super.key});

  IconData _iconFor(String platform) {
    switch (platform) {
      case 'android':
      case 'ios':
        return Icons.smartphone;
      case 'web':
        return Icons.public;
      case 'windows':
      case 'linux':
      case 'macos':
        return Icons.desktop_windows;
      default:
        return Icons.devices_other;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(syncProvider);
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 12),
          Container(
            width: 40, height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                const Icon(Icons.devices, color: AppColors.primary),
                const SizedBox(width: 8),
                Text('Dispositivos conectados',
                    style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                if (!sync.connected)
                  const Text('Desconectado',
                      style: TextStyle(color: AppColors.error, fontSize: 11)),
              ],
            ),
          ),
          const Divider(),
          if (sync.devices.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Apenas este dispositivo está conectado. Abra o app em outro lugar para vê-lo aqui.',
                style: TextStyle(color: AppColors.textSecondary),
                textAlign: TextAlign.center,
              ),
            )
          else
            ...sync.devices.map((d) {
              final isActive = d.id == sync.activeDeviceId;
              final isThis = d.id == sync.deviceId;
              return ListTile(
                leading: Icon(
                  _iconFor(d.platform),
                  color: isActive ? AppColors.primary : AppColors.textPrimary,
                ),
                title: Row(
                  children: [
                    Expanded(child: Text(d.name)),
                    if (isThis)
                      const Padding(
                        padding: EdgeInsets.only(left: 6),
                        child: Text('(este)',
                            style: TextStyle(color: AppColors.textSecondary, fontSize: 11)),
                      ),
                  ],
                ),
                subtitle: Text(
                  isActive ? 'Tocando agora' : 'Disponível',
                  style: TextStyle(
                    color: isActive ? AppColors.primary : AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
                trailing: isActive
                    ? const Icon(Icons.volume_up, color: AppColors.primary)
                    : const Icon(Icons.swap_horiz, color: AppColors.textSecondary),
                onTap: isActive
                    ? null
                    : () {
                        ref.read(syncProvider.notifier).transferTo(d.id);
                        Navigator.pop(context);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Transferindo para ${d.name}...')),
                        );
                      },
              );
            }),
          if (sync.devices.isNotEmpty && !sync.isActiveDevice)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: FilledButton.icon(
                onPressed: () {
                  ref.read(syncProvider.notifier).takeControl();
                  Navigator.pop(context);
                },
                icon: const Icon(Icons.headset),
                label: const Text('Tocar neste dispositivo'),
              ),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
