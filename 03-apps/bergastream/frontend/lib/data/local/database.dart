import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/app_platform.dart';
import '../../core/widgets/download_state_icon.dart';
import '../models/playlist_models.dart';
import '../models/search_result.dart';

part 'database.g.dart';

/// Faixa guardada no aparelho (Seção 8.1): áudio, capa e metadados.
@DataClassName('LocalTrack')
class LocalTracks extends Table {
  /// Id da faixa no servidor.
  TextColumn get id => text()();
  TextColumn get provider => text()();
  TextColumn get externalId => text()();
  TextColumn get title => text()();
  TextColumn get artist => text()();
  TextColumn get album => text().withDefault(const Constant(''))();
  IntColumn get durationSeconds => integer().withDefault(const Constant(0))();
  TextColumn get isrc => text().nullable()();
  TextColumn get coverUrl => text().nullable()();
  TextColumn get coverPath => text().nullable()();
  TextColumn get audioPath => text().nullable()();
  IntColumn get sizeBytes => integer().nullable()();
  IntColumn get downloadState => intEnum<DownloadState>()();
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  DateTimeColumn get downloadedAt => dateTime().nullable()();
  DateTimeColumn get lastPlayedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Playlist do servidor baixada no aparelho (espelho para uso offline).
@DataClassName('LocalPlaylistRow')
class LocalPlaylists extends Table {
  /// Id da playlist no servidor.
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get coverUrl => text().nullable()();
  TextColumn get coverPath => text().nullable()();
  TextColumn get owner => text().withDefault(const Constant(''))();
  TextColumn get role => text().withDefault(const Constant('owner'))();

  /// `updated_at` do servidor quando foi sincronizada (Passo 11).
  TextColumn get serverUpdatedAt => text().nullable()();
  BoolColumn get paused => boolean().withDefault(const Constant(false))();
  DateTimeColumn get downloadedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('LocalPlaylistItem')
class LocalPlaylistItems extends Table {
  TextColumn get playlistId => text()();
  TextColumn get trackId => text()();
  IntColumn get position => integer()();
  TextColumn get addedBy => text().nullable()();
  TextColumn get addedAt => text().nullable()();

  @override
  Set<Column> get primaryKey => {playlistId, trackId};
}

@DataClassName('LocalCollaborator')
class LocalCollaborators extends Table {
  TextColumn get playlistId => text()();
  TextColumn get userName => text()();
  TextColumn get role => text()();

  @override
  Set<Column> get primaryKey => {playlistId, userName};
}

/// Reproduções feitas offline, a enviar ao servidor (Passo 11).
@DataClassName('PendingPlay')
class PendingPlays extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get trackJson => text()();
  DateTimeColumn get playedAt => dateTime()();
}

/// Chave/valor: preferências e caches (ex.: métricas da tela inicial).
@DataClassName('AppStateEntry')
class AppState extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

/// Progresso de uma playlist baixada (Seção 8.2).
enum PlaylistDownloadState { naoBaixada, baixando, parcial, baixada }

class PlaylistDownloadProgress {
  const PlaylistDownloadProgress({
    required this.state,
    required this.done,
    required this.total,
    required this.failed,
    required this.paused,
    required this.bytes,
  });

  static const none = PlaylistDownloadProgress(
    state: PlaylistDownloadState.naoBaixada,
    done: 0,
    total: 0,
    failed: 0,
    paused: false,
    bytes: 0,
  );

  final PlaylistDownloadState state;
  final int done;
  final int total;
  final int failed;
  final bool paused;
  final int bytes;

  int get remaining => total - done;
}

@DriftDatabase(
  tables: [
    LocalTracks,
    LocalPlaylists,
    LocalPlaylistItems,
    LocalCollaborators,
    PendingPlays,
    AppState,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  /// Banco do app no aparelho (`bergastream.sqlite`).
  factory AppDatabase.open() => AppDatabase(driftDatabase(name: 'bergastream'));

  /// Versões e migrações desde o início (Seção 10).
  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) async {
      // Próximas versões: migrações passo a passo a partir de [from].
    },
  );

  // ── Playlists baixadas ────────────────────────────────────────

  /// Guarda (ou atualiza) a playlist para download: metadados, ordem, quem
  /// adicionou e colaboradores. Faixas novas entram na fila; as que já
  /// estão baixadas por outra playlist são reaproveitadas. Devolve os ids
  /// das faixas que saíram da playlist (para revisar a permanência).
  Future<List<String>> savePlaylist(PlaylistDetail p) => transaction(() async {
    await into(localPlaylists).insertOnConflictUpdate(
      LocalPlaylistsCompanion.insert(
        id: p.id,
        name: p.name,
        coverUrl: Value(p.coverUrl),
        owner: Value(p.owner?.name ?? ''),
        role: Value(p.role),
        serverUpdatedAt: Value(p.updatedAt),
        downloadedAt: DateTime.now(),
      ),
    );
    final before =
        (await (select(
              localPlaylistItems,
            )..where((i) => i.playlistId.equals(p.id))).get())
            .map((i) => i.trackId)
            .toSet();
    await (delete(
      localPlaylistItems,
    )..where((i) => i.playlistId.equals(p.id))).go();
    await (delete(
      localCollaborators,
    )..where((c) => c.playlistId.equals(p.id))).go();
    for (final (i, t) in p.tracks.indexed) {
      await into(localTracks).insert(
        LocalTracksCompanion.insert(
          id: t.trackId,
          provider: t.provider,
          externalId: t.externalId,
          title: t.title,
          artist: t.artist,
          album: Value(t.album),
          durationSeconds: Value(t.durationSeconds),
          isrc: Value(t.isrc),
          coverUrl: Value(t.coverUrl),
          sizeBytes: Value(t.sizeBytes),
          downloadState: DownloadState.naFila,
        ),
        mode: InsertMode.insertOrIgnore,
      );
      // Faixa que falhou antes volta para a fila ao baixar de novo.
      await (update(localTracks)..where(
            (x) =>
                x.id.equals(t.trackId) &
                x.downloadState.equalsValue(DownloadState.falhou),
          ))
          .write(
            const LocalTracksCompanion(
              downloadState: Value(DownloadState.naFila),
              attempts: Value(0),
            ),
          );
      await into(localPlaylistItems).insert(
        LocalPlaylistItemsCompanion.insert(
          playlistId: p.id,
          trackId: t.trackId,
          position: i,
          addedBy: Value(t.addedBy?.name),
          addedAt: Value(t.addedAt),
        ),
      );
    }
    for (final m in [
      if (p.owner != null) (p.owner!.name, 'owner'),
      for (final m in p.members) (m.user.name, m.role),
    ]) {
      await into(localCollaborators).insertOnConflictUpdate(
        LocalCollaboratorsCompanion.insert(
          playlistId: p.id,
          userName: m.$1,
          role: m.$2,
        ),
      );
    }
    final now = {for (final t in p.tracks) t.trackId};
    return [
      for (final id in before)
        if (!now.contains(id)) id,
    ];
  });

  Stream<List<LocalPlaylistRow>> watchPlaylists() => (select(
    localPlaylists,
  )..orderBy([(p) => OrderingTerm.asc(p.name)])).watch();

  Future<LocalPlaylistRow?> playlist(String id) =>
      (select(localPlaylists)..where((p) => p.id.equals(id))).getSingleOrNull();

  Future<void> setPaused(String playlistId, bool paused) =>
      (update(localPlaylists)..where((p) => p.id.equals(playlistId))).write(
        LocalPlaylistsCompanion(paused: Value(paused)),
      );

  /// Faixas da playlist na ordem, com quem adicionou.
  Stream<List<(LocalTrack, LocalPlaylistItem)>> watchPlaylistTracks(
    String playlistId,
  ) {
    final query =
        select(localPlaylistItems).join([
            innerJoin(
              localTracks,
              localTracks.id.equalsExp(localPlaylistItems.trackId),
            ),
          ])
          ..where(localPlaylistItems.playlistId.equals(playlistId))
          ..orderBy([OrderingTerm.asc(localPlaylistItems.position)]);
    return query.watch().map(
      (rows) => [
        for (final r in rows)
          (r.readTable(localTracks), r.readTable(localPlaylistItems)),
      ],
    );
  }

  Future<List<LocalCollaborator>> collaborators(String playlistId) => (select(
    localCollaborators,
  )..where((c) => c.playlistId.equals(playlistId))).get();

  Stream<List<LocalCollaborator>> watchCollaborators(String playlistId) =>
      (select(
        localCollaborators,
      )..where((c) => c.playlistId.equals(playlistId))).watch();

  /// Progresso da playlist (Seção 8.2/8.4).
  Stream<PlaylistDownloadProgress> watchProgress(String playlistId) {
    final tracks = watchPlaylistTracks(playlistId);
    return tracks.asyncMap((rows) async {
      final p = await playlist(playlistId);
      if (p == null) return PlaylistDownloadProgress.none;
      final done = rows.where(
        (r) => r.$1.downloadState == DownloadState.baixada,
      );
      final failed = rows
          .where((r) => r.$1.downloadState == DownloadState.falhou)
          .length;
      final pending = rows.length - done.length - failed;
      return PlaylistDownloadProgress(
        state: pending > 0 && !p.paused
            ? PlaylistDownloadState.baixando
            : done.length == rows.length
            ? PlaylistDownloadState.baixada
            : PlaylistDownloadState.parcial,
        done: done.length,
        total: rows.length,
        failed: failed,
        paused: p.paused,
        bytes: done.fold(0, (sum, r) => sum + (r.$1.sizeBytes ?? 0)),
      );
    });
  }

  /// Remove o download da playlist. Devolve as faixas que não estão em
  /// nenhuma outra playlist baixada (os arquivos delas devem ser apagados):
  /// contagem de referências da Seção 8.3.
  Future<List<LocalTrack>> removePlaylist(String playlistId) =>
      transaction(() async {
        final ids =
            (await (select(
                  localPlaylistItems,
                )..where((i) => i.playlistId.equals(playlistId))).get())
                .map((i) => i.trackId)
                .toList();
        await (delete(
          localPlaylistItems,
        )..where((i) => i.playlistId.equals(playlistId))).go();
        await (delete(
          localCollaborators,
        )..where((c) => c.playlistId.equals(playlistId))).go();
        await (delete(
          localPlaylists,
        )..where((p) => p.id.equals(playlistId))).go();
        return releaseTracks(ids);
      });

  /// Das faixas [ids], apaga do banco (e devolve) as que não estão em mais
  /// nenhuma playlist baixada.
  Future<List<LocalTrack>> releaseTracks(Iterable<String> ids) async {
    final orphans = <LocalTrack>[];
    for (final id in ids) {
      final refs = await (select(
        localPlaylistItems,
      )..where((i) => i.trackId.equals(id))).get();
      if (refs.isNotEmpty) continue;
      final track = await (select(
        localTracks,
      )..where((t) => t.id.equals(id))).getSingleOrNull();
      if (track == null) continue;
      orphans.add(track);
      await (delete(localTracks)..where((t) => t.id.equals(id))).go();
    }
    return orphans;
  }

  // ── Faixas ────────────────────────────────────────────────────

  /// Próximas faixas a baixar (na fila ou interrompidas), de playlists que
  /// não estão pausadas.
  Future<List<LocalTrack>> queuedTracks() {
    final query =
        select(localTracks).join([
            innerJoin(
              localPlaylistItems,
              localPlaylistItems.trackId.equalsExp(localTracks.id),
            ),
            innerJoin(
              localPlaylists,
              localPlaylists.id.equalsExp(localPlaylistItems.playlistId),
            ),
          ])
          ..where(
            localTracks.downloadState.isInValues([
                  DownloadState.naFila,
                  DownloadState.baixando,
                ]) &
                localPlaylists.paused.equals(false),
          )
          ..orderBy([OrderingTerm.asc(localPlaylistItems.position)]);
    return query
        .map((r) => r.readTable(localTracks))
        .get()
        .then((list) => {for (final t in list) t.id: t}.values.toList());
  }

  Future<void> updateTrack(String id, LocalTracksCompanion changes) =>
      (update(localTracks)..where((t) => t.id.equals(id))).write(changes);

  Future<LocalTrack?> track(String id) =>
      (select(localTracks)..where((t) => t.id.equals(id))).getSingleOrNull();

  /// Faixa baixada correspondente a um resultado (para tocar o arquivo
  /// local primeiro, Seção 7.3).
  Future<LocalTrack?> downloadedFor(SearchResult r) =>
      (select(localTracks)..where(
            (t) =>
                t.provider.equals(r.provider) &
                t.externalId.equals(r.externalId) &
                t.downloadState.equalsValue(DownloadState.baixada),
          ))
          .getSingleOrNull();

  Stream<Map<String, DownloadState>> watchStates() =>
      select(localTracks).watch().map(
        (rows) => {
          for (final t in rows)
            '${t.provider}:${t.externalId}': t.downloadState,
        },
      );

  /// Busca local (Seção 2.4): nas músicas baixadas.
  Future<List<LocalTrack>> searchDownloaded(String query) {
    final q = '%${query.trim().toLowerCase()}%';
    return (select(localTracks)..where(
          (t) =>
              t.downloadState.equalsValue(DownloadState.baixada) &
              (t.title.lower().like(q) |
                  t.artist.lower().like(q) |
                  t.album.lower().like(q)),
        ))
        .get();
  }

  /// Espaço usado pelos downloads, em bytes.
  Future<int> usedBytes() async {
    final rows = await (select(
      localTracks,
    )..where((t) => t.downloadState.equalsValue(DownloadState.baixada))).get();
    return rows.fold<int>(0, (sum, t) => sum + (t.sizeBytes ?? 0));
  }

  Stream<int> watchDownloadedCount() =>
      (select(localTracks)
            ..where((t) => t.downloadState.equalsValue(DownloadState.baixada)))
          .watch()
          .map((r) => r.length);

  // ── Reproduções pendentes e estado ────────────────────────────

  Future<void> addPendingPlay(String trackJson, DateTime at) => into(
    pendingPlays,
  ).insert(PendingPlaysCompanion.insert(trackJson: trackJson, playedAt: at));

  Future<List<PendingPlay>> pendingPlaysInOrder() =>
      (select(pendingPlays)..orderBy([(p) => OrderingTerm.asc(p.id)])).get();

  Future<void> deletePendingPlays(Iterable<int> ids) =>
      (delete(pendingPlays)..where((p) => p.id.isIn(ids))).go();

  Future<String?> stateValue(String key) async => (await (select(
    appState,
  )..where((s) => s.key.equals(key))).getSingleOrNull())?.value;

  Future<void> setStateValue(String key, String value) => into(
    appState,
  ).insertOnConflictUpdate(AppStateCompanion.insert(key: key, value: value));
}

/// Banco local. Nulo na web (inclusive na simulação do Android no
/// navegador): lá não há downloads (Seção 2.1).
final localDatabaseProvider = Provider<AppDatabase?>((ref) {
  final platform = ref.watch(appPlatformProvider);
  if (platform.isWeb || platform.simulated) return null;
  final db = AppDatabase.open();
  ref.onDispose(db.close);
  return db;
});

/// Converte a faixa local em resultado para o player e o menu ⋮.
extension LocalTrackResult on LocalTrack {
  SearchResult get asResult => SearchResult(
    provider: provider,
    externalId: externalId,
    title: title,
    artist: artist,
    album: album,
    durationSeconds: durationSeconds,
    isrc: isrc,
    coverUrl: coverUrl,
  );
}
