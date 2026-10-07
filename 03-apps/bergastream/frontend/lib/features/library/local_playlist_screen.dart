import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/routes.dart';
import '../../core/platform/app_layout.dart';
import '../../core/theme/berga_colors.dart';
import '../../core/theme/berga_sizes.dart';
import '../../core/theme/berga_text.dart';
import '../../core/widgets/widgets.dart';
import '../../data/repositories/local_playlists.dart';

/// Playlist criada sem login ("Só neste aparelho"). Pode ser editada offline;
/// as músicas vêm das baixadas (Passo 9).
class LocalPlaylistScreen extends ConsumerWidget {
  const LocalPlaylistScreen({super.key, required this.id});

  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = BergaColors.of(context);
    final mu = BergaText.secondary.copyWith(color: c.mu);
    final playlists = ref.watch(localPlaylistsProvider);
    final p = playlists.where((p) => p.id == id).firstOrNull;
    final notifier = ref.read(localPlaylistsProvider.notifier);

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: AppLayout.screenPadding(context),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: GestureDetector(
                onTap: () => context.canPop()
                    ? context.pop()
                    : context.go(AppRoutes.library),
                child: Text('‹ Biblioteca', style: mu),
              ),
            ),
            if (p == null)
              Padding(
                padding: const EdgeInsets.only(top: 20),
                child: Text('Playlist não encontrada.', style: mu),
              )
            else ...[
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child: Cover.playlist(
                  size: BergaSizes.playlistCoverMaxHeight,
                  initialSize: 60,
                ),
              ),
              ScreenTitle(p.name, bottom: 4),
              Text(
                '${p.trackIds.length} músicas · Só neste aparelho',
                style: mu,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Wrap(
                  spacing: 10,
                  children: [
                    AppChip(
                      label: 'Renomear',
                      onTap: () async {
                        final name = await showTextInputDialog(
                          context,
                          title: 'Renomear playlist',
                          hint: 'Nome da playlist',
                          initial: p.name,
                        );
                        if (name != null) await notifier.rename(p.id, name);
                      },
                    ),
                    AppChip(
                      label: 'Apagar',
                      onTap: () async {
                        await notifier.delete(p.id);
                        if (context.mounted) context.pop();
                      },
                    ),
                  ],
                ),
              ),
              if (p.trackIds.isEmpty)
                Text(
                  'Vazia. Adicione músicas baixadas a esta playlist.',
                  style: mu,
                ),
            ],
          ],
        ),
      ),
    );
  }
}
