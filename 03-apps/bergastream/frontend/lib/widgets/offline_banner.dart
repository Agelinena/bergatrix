import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/theme/app_theme.dart';
import '../providers/connectivity_provider.dart';

/// Small, non-intrusive banner shown at the top of every screen when the
/// device is offline.  Tapping it triggers a refresh of the connectivity
/// check (in case Android failed to fire the change event).
///
/// Designed to slot into MainScaffold above the route's body.  Returns
/// `SizedBox.shrink()` when online so the layout collapses cleanly.
class OfflineBanner extends ConsumerWidget {
  const OfflineBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final online = ref.watch(connectivityProvider);
    if (online) return const SizedBox.shrink();
    return Material(
      color: Colors.orange.shade800,
      child: InkWell(
        onTap: () => ref.read(connectivityProvider.notifier).refresh(),
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.wifi_off, color: Colors.white, size: 14),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Sem conexão — usando dados locais. Toque para verificar.',
                  style: TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
