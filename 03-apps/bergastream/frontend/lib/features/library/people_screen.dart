import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_error.dart';
import '../../core/platform/app_layout.dart';
import '../../core/theme/berga_colors.dart';
import '../../core/theme/berga_sizes.dart';
import '../../core/theme/berga_text.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/playlist_models.dart';
import '../../data/repositories/playlist_repository.dart';
import 'library_providers.dart';

/// Tela "Pessoas" da playlist (Seção 6.4): o dono define, para cada usuário
/// do servidor, se vê, edita ou não tem acesso.
class PeopleScreen extends ConsumerStatefulWidget {
  const PeopleScreen({super.key, required this.id});

  final String id;

  @override
  ConsumerState<PeopleScreen> createState() => _PeopleScreenState();
}

class _PeopleScreenState extends ConsumerState<PeopleScreen> {
  late final Future<List<Person>> _users = ref
      .read(playlistRepositoryProvider)
      .directory();

  Future<void> _set(String userId, PlaylistRole? role) async {
    final repo = ref.read(playlistRepositoryProvider);
    try {
      if (role == null) {
        await repo.removeMember(widget.id, userId);
      } else {
        await repo.setMember(widget.id, userId, role);
      }
      ref.invalidate(playlistDetailProvider(widget.id));
      ref.invalidate(myPlaylistsProvider);
    } on ApiException catch (e) {
      if (mounted) AppToast.show(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = BergaColors.of(context);
    final mu = BergaText.secondary.copyWith(color: c.mu);
    final detail = ref.watch(playlistDetailProvider(widget.id));
    return Scaffold(
      body: SafeArea(
        child: FutureBuilder<List<Person>>(
          future: _users,
          builder: (context, snapshot) {
            final p = detail.value;
            final roles = {
              for (final m in p?.members ?? const <PlaylistMember>[])
                m.user.id: PlaylistRole.parse(m.role),
            };
            final users = [
              for (final u in snapshot.data ?? const <Person>[])
                if (u.id != p?.owner?.id) u,
            ];
            return ListView(
              padding: AppLayout.screenPadding(context),
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: GestureDetector(
                    onTap: () => context.pop(),
                    child: Text('‹ ${p?.name ?? 'Playlist'}', style: mu),
                  ),
                ),
                const SizedBox(height: 10),
                const ScreenTitle('Pessoas'),
                Text(
                  'Quem vê pode ouvir e baixar. Quem edita também adiciona, '
                  'remove e reordena músicas.',
                  style: mu,
                ),
                if (snapshot.connectionState != ConnectionState.done)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text('Carregando…', style: mu),
                  ),
                if (snapshot.hasError)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(
                      'Não foi possível carregar os usuários.',
                      style: mu,
                    ),
                  ),
                for (final u in users)
                  Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          u.name,
                          style: BergaText.trackTitle.copyWith(color: c.tx),
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: BergaSizes.chipGap,
                          children: [
                            for (final (label, role) in [
                              ('Sem acesso', null),
                              ('Vê', PlaylistRole.viewer),
                              ('Edita', PlaylistRole.editor),
                            ])
                              AppChip(
                                label: label,
                                active: roles[u.id] == role,
                                onTap: () => _set(u.id, role),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
