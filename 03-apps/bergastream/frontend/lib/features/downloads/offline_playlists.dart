import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local/database.dart';
import '../../data/models/playlist_models.dart';

/// Playlist baixada lida do banco local, no mesmo formato do servidor (para
/// a mesma tela funcionar sem servidor). Somente leitura.
final offlinePlaylistProvider = StreamProvider.autoDispose
    .family<PlaylistDetail?, String>((ref, id) {
      final db = ref.watch(localDatabaseProvider);
      if (db == null) return Stream.value(null);
      // Reage às faixas (estado do download); playlist e colaboradores são
      // lidos a cada mudança.
      return db.watchPlaylistTracks(id).asyncMap((rows) async {
        final playlist = await db.playlist(id);
        if (playlist == null) return null;
        final collaborators = await db.collaborators(id);
        return PlaylistDetail(
          id: id,
          name: playlist.name,
          owner: Person(id: '', username: '', name: playlist.owner),
          role: 'viewer',
          coverUrl: playlist.coverUrl,
          updatedAt: playlist.serverUpdatedAt,
          members: [
            for (final c in collaborators)
              if (c.role != 'owner')
                PlaylistMember(
                  user: Person(id: '', username: '', name: c.userName),
                  role: c.role,
                ),
          ],
          tracks: [
            for (final (track, item) in rows)
              PlaylistTrack(
                trackId: track.id,
                provider: track.provider,
                externalId: track.externalId,
                title: track.title,
                artist: track.artist,
                album: track.album,
                durationSeconds: track.durationSeconds,
                isrc: track.isrc,
                // Capa baixada primeiro (Seção 8.1).
                coverUrl: track.coverPath != null
                    ? Uri.file(track.coverPath!).toString()
                    : track.coverUrl,
                addedBy: item.addedBy == null
                    ? null
                    : Person(id: '', username: '', name: item.addedBy!),
                addedAt: item.addedAt ?? '',
                position: item.position,
                ready: true,
                sizeBytes: track.sizeBytes,
              ),
          ],
        );
      });
    });
