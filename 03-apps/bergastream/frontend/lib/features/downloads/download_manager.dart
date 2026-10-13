import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/network/api_error.dart';
import '../../core/network/connectivity.dart';
import '../../core/widgets/download_state_icon.dart';
import '../../data/local/database.dart';
import '../../data/models/playlist_models.dart';
import '../../data/repositories/playback_repository.dart';
import '../auth/session.dart';
import '../player/player_controller.dart';
import '../settings/preferences.dart';
import 'file_fetcher.dart';

/// Pastas dos downloads (áudio e capas).
class DownloadPaths {
  const DownloadPaths({required this.audio, required this.covers});

  final String audio;
  final String covers;

  static Future<DownloadPaths> appDocuments() async {
    final base = (await getApplicationDocumentsDirectory()).path;
    final paths = DownloadPaths(
      audio: '$base/bergastream/audio',
      covers: '$base/bergastream/capas',
    );
    await Directory(paths.audio).create(recursive: true);
    await Directory(paths.covers).create(recursive: true);
    return paths;
  }
}

/// Se dá para baixar agora (Wi-Fi quando "Baixar só no Wi-Fi" está ligado).
abstract interface class NetworkCheck {
  Future<bool> onWifi();
  Stream<void> get changes;
}

class ConnectivityNetworkCheck implements NetworkCheck {
  @override
  Future<bool> onWifi() async {
    final types = await SafeConnectivity.current();
    return types.contains(ConnectivityResult.wifi) ||
        types.contains(ConnectivityResult.ethernet);
  }

  @override
  Stream<void> get changes => SafeConnectivity.changes();
}

/// Estado geral dos downloads (para avisos na tela).
class DownloadsStatus {
  const DownloadsStatus({
    this.active = 0,
    this.waitingForWifi = false,
    this.upgrading = 0,
    this.upgraded,
  });

  final int active;
  final bool waitingForWifi;

  /// Cópias esperando a troca por qualidade melhor (ou outra escolhida).
  final int upgrading;

  /// Lote de trocas terminado: aviso para mostrar uma vez.
  final UpgradeNotice? upgraded;
}

/// "N músicas trocadas por qualidade melhor" (cada aviso com id novo).
class UpgradeNotice {
  UpgradeNotice(this.count) : id = _ids++;

  static int _ids = 0;
  final int id;
  final int count;
}

/// Chave da preferência "Baixar só no Wi-Fi" (padrão: ligado).
const wifiOnlyKey = 'downloads.wifi_only';

/// Gerenciador de downloads (Seção 8.5): 2 simultâneos, retomada após
/// fechar o app, até 3 tentativas com espera crescente, "só no Wi-Fi",
/// preparo no servidor e validação. A faixa só vira "baixada" com áudio
/// válido, capa e metadados salvos.
class DownloadManager extends Notifier<DownloadsStatus> {
  DownloadManager();

  static const maxConcurrent = 2;
  static const maxAttempts = 3;

  /// Espera antes da nova tentativa: base × 2^(tentativa-1).
  Duration retryBase = const Duration(seconds: 2);

  final _running = <String>{};
  final _retryAt = <String, DateTime>{};
  Timer? _retryTimer;

  /// Falha passageira (rede, servidor fora): tenta de novo depois disto,
  /// sem contar tentativa.
  Duration transientRetry = const Duration(seconds: 30);

  /// Trocas de qualidade feitas no lote atual (para o aviso no fim).
  int _upgradedInBatch = 0;
  int _upgrading = 0;
  UpgradeNotice? _lastNotice;
  StreamSubscription<void>? _network;
  Future<DownloadPaths>? _paths;
  bool _pumping = false;

  AppDatabase get _db => ref.read(localDatabaseProvider)!;

  @override
  DownloadsStatus build() {
    // Sem servidor não há o que baixar; ao voltar, continua (Seção 8.5).
    ref.listen(sessionProvider.select((s) => s.canUseServer), (_, online) {
      if (online) pump();
    });
    ref.onDispose(() {
      _retryTimer?.cancel();
      _network?.cancel();
    });
    return const DownloadsStatus();
  }

  bool get available => ref.read(localDatabaseProvider) != null;

  Future<DownloadPaths> get paths =>
      _paths ??= ref.read(downloadPathsProvider)();

  /// Retoma o que ficou pendente (app fechado no meio).
  Future<void> start() async {
    if (!available) return;
    _network ??= ref.read(networkCheckProvider).changes.listen((_) => pump());
    await pump();
  }

  /// "Baixar no aparelho" / "Baixar restantes" / "Atualizar download".
  /// Faixas que saíram da playlist no servidor são liberadas (Seção 8.3).
  Future<void> downloadPlaylist(PlaylistDetail playlist) async {
    await requestDownloadNotifications();
    final gone = await _db.savePlaylist(playlist);
    await _db.setPaused(playlist.id, false);
    await _deleteFiles(await _db.releaseTracks(gone));
    await pump();
  }

  Future<void> pause(String playlistId) => _db.setPaused(playlistId, true);

  Future<void> resume(String playlistId) async {
    await _db.setPaused(playlistId, false);
    await pump();
  }

  /// Remove o download (e "Cancelar"): apaga só os arquivos que nenhuma
  /// outra playlist baixada usa.
  Future<void> removeDownload(String playlistId) async {
    await _deleteFiles(await _db.removePlaylist(playlistId));
  }

  /// "Apagar todos os downloads".
  Future<void> removeAll() async {
    for (final p in await _db.watchPlaylists().first) {
      await removeDownload(p.id);
    }
  }

  Future<void> _deleteFiles(List<LocalTrack> tracks) async {
    for (final t in tracks) {
      for (final path in [t.audioPath, t.coverPath]) {
        if (path != null) await _deleteQuietly(path);
      }
    }
  }

  static Future<void> _deleteQuietly(String path) async {
    try {
      await File(path).delete();
    } on FileSystemException {
      // Já não existe.
    }
  }

  /// Começa downloads até o limite de simultâneos.
  Future<void> pump() async {
    if (!available || _pumping) return;
    if (!ref.read(sessionProvider).canUseServer) return;
    _pumping = true;
    try {
      final wifiOnly = await _db.stateValue(wifiOnlyKey) != 'false';
      if (wifiOnly && !await ref.read(networkCheckProvider).onWifi()) {
        _publish(waitingForWifi: true);
        return;
      }
      final now = DateTime.now();
      final all = await _db.queuedTracks();
      _upgrading = all
          .where(
            (t) => t.downloadState == DownloadState.baixada && t.needsReplace,
          )
          .length;
      final queue = [
        for (final t in all)
          if (!_running.contains(t.id) &&
              !(_retryAt[t.id]?.isAfter(now) ?? false))
            t,
      ];
      // Alguma esperando a nova tentativa: garante o timer (ele pode disparar
      // um instante antes da hora e a faixa ficaria parada na fila).
      if (all.any((t) => _retryAt[t.id]?.isAfter(now) ?? false)) {
        _scheduleRetry();
      }
      for (final t in queue.take(maxConcurrent - _running.length)) {
        _running.add(t.id);
        unawaited(
          _download(t).whenComplete(() {
            _running.remove(t.id);
            _publish();
            pump();
          }),
        );
      }
      _publish();
    } finally {
      _pumping = false;
    }
  }

  void _publish({bool waitingForWifi = false}) {
    if (!ref.mounted) return;
    if (_upgrading == 0 && _upgradedInBatch > 0 && _running.isEmpty) {
      // Fica no estado até o próximo lote (a tela compara pelo id).
      _lastNotice = UpgradeNotice(_upgradedInBatch);
      _upgradedInBatch = 0;
    }
    state = DownloadsStatus(
      active: _running.length,
      waitingForWifi: waitingForWifi,
      upgrading: _upgrading,
      upgraded: _lastNotice,
    );
  }

  /// Próxima nova tentativa: um timer até a mais próxima (antes um só,
  /// sobrescrito a cada falha, deixava faixas paradas).
  void _scheduleRetry() {
    _retryTimer?.cancel();
    if (_retryAt.isEmpty) return;
    final next = _retryAt.values.reduce((a, b) => a.isBefore(b) ? a : b);
    var wait = next.difference(DateTime.now());
    if (wait < Duration.zero) wait = Duration.zero;
    _retryTimer = Timer(wait + const Duration(milliseconds: 5), pump);
  }

  static bool _isTransient(Object e) =>
      e is TransientFetchError ||
      e is SocketException ||
      (e is ApiException && e.isTransient);

  /// Confere com o servidor a qualidade das cópias baixadas e marca para
  /// trocar as que mudaram: a qualidade escolhida para downloads mudou, ou o
  /// servidor melhorou a música (ex.: ganhou o FLAC). Compara o que o
  /// servidor entrega no nível escolhido ("MP3 320"), então mudar de nível
  /// sem mudar o resultado não baixa nada. Cópias antigas (sem qualidade
  /// registrada) são trocadas uma vez. Devolve quantas vão ser trocadas.
  Future<int> refreshQuality() async {
    if (!available || !ref.read(sessionProvider).canUseServer) return 0;
    await ref.read(preferencesProvider.notifier).ready;
    final level = ref.read(preferencesProvider).offlineQuality.api;
    final playback = ref.read(playbackRepositoryProvider);
    final tracks = await _db.downloadedTracks();
    final stale = <String>[];
    for (var start = 0; start < tracks.length; start += 500) {
      final chunk = tracks.skip(start).take(500).toList();
      final server = await playback.qualities([
        for (final t in chunk) '${t.provider}:${t.externalId}',
      ]);
      for (final t in chunk) {
        final expected = server['${t.provider}:${t.externalId}']?[level];
        if (expected == null) continue; // sem arquivo no servidor: fica a cópia
        if (t.qualityLabel != expected.label) {
          stale.add(t.id);
        } else if (t.qualityLevel != level) {
          // Mesmo resultado no nível novo: só anota.
          await _db.updateTrack(
            t.id,
            LocalTracksCompanion(qualityLevel: Value(level)),
          );
        }
      }
    }
    await _db.markForReplace(stale);
    if (stale.isNotEmpty) await pump();
    return stale.length;
  }

  Future<void> _download(LocalTrack t) async {
    final dirs = await paths;
    final playback = ref.read(playbackRepositoryProvider);
    final fetcher = ref.read(fileFetcherProvider);
    final timings = ref.read(playerTimingsProvider);
    final partial = '${dirs.audio}/${t.id}.part';
    // Troca de qualidade: a cópia atual segue tocando até a nova chegar e
    // fica se a troca falhar.
    final replacing =
        t.downloadState == DownloadState.baixada && t.needsReplace;
    String? audioPath;
    String? coverPath;
    if (!replacing) {
      await _db.updateTrack(
        t.id,
        const LocalTracksCompanion(
          downloadState: Value(DownloadState.baixando),
        ),
      );
    }
    try {
      await ref.read(preferencesProvider.notifier).ready;
      final level = ref.read(preferencesProvider).offlineQuality.api;
      // 1. A faixa precisa estar pronta no servidor.
      final prepared = await playback.prepare(t.asResult);
      var readiness = prepared.readiness;
      final deadline = DateTime.now().add(timings.prepareTimeout);
      while (readiness != TrackReadiness.pronta) {
        if (readiness == TrackReadiness.erro ||
            DateTime.now().isAfter(deadline)) {
          throw const ApiException(ApiErrorKind.requisicao);
        }
        await Future<void>.delayed(timings.pollInterval);
        readiness = await playback.status(prepared.trackId);
      }

      // 2. Áudio, validado pelo tamanho.
      final audio = await fetcher.fetch(
        await playback.downloadUrl(prepared.trackId, quality: level),
        partial,
        label: '${t.title} · ${t.artist}',
      );
      if (audio.bytes <= 0 ||
          (audio.expectedBytes != null && audio.bytes != audio.expectedBytes)) {
        throw FileSystemException('Arquivo incompleto', partial);
      }
      // Sem o cabeçalho de qualidade (alguns Android não repassam): pergunta
      // ao servidor. Sem isso a cópia ficava sem rótulo e era baixada de
      // novo a cada conferência.
      var quality = audio.quality;
      if (quality == null || quality.isEmpty) {
        final ref_ = '${t.provider}:${t.externalId}';
        try {
          quality = (await playback.qualities([ref_]))[ref_]?[level]?.label;
        } on Object catch (e) {
          debugPrint('Qualidade não informada (${t.title}): $e');
        }
      }
      audioPath = '${dirs.audio}/${t.id}.${audio.format ?? 'mp3'}';
      final previous = t.audioPath;
      // O rename não substitui arquivo existente em todas as plataformas.
      if (await File(audioPath).exists()) await File(audioPath).delete();
      await File(partial).rename(audioPath);
      // Formato mudou (ex.: flac → m4a): a cópia antiga tem outro nome.
      if (previous != null && previous != audioPath) {
        await _deleteQuietly(previous);
      }

      // 3. Capa (a UI usa o arquivo local antes da URL); na troca de
      // qualidade, a que já está no aparelho serve.
      if (replacing && t.coverPath != null && File(t.coverPath!).existsSync()) {
        coverPath = t.coverPath;
      } else if (t.coverUrl != null) {
        coverPath = '${dirs.covers}/${t.id}.img';
        final cover = await fetcher.fetch(Uri.parse(t.coverUrl!), coverPath);
        if (cover.bytes <= 0) {
          throw FileSystemException('Capa vazia', coverPath);
        }
      }

      // 4. Metadados e estado juntos: só agora vira "baixada".
      await _db.updateTrack(
        t.id,
        LocalTracksCompanion(
          audioPath: Value(audioPath),
          coverPath: Value(coverPath),
          sizeBytes: Value(audio.bytes),
          downloadState: const Value(DownloadState.baixada),
          downloadedAt: Value(DateTime.now()),
          attempts: const Value(0),
          qualityLevel: Value(level),
          qualityLabel: Value(quality),
          needsReplace: const Value(false),
        ),
      );
      _retryAt.remove(t.id);
      if (replacing) {
        _upgradedInBatch++;
        if (_upgrading > 0) _upgrading--;
      }
    } on Object catch (e) {
      debugPrint('Download falhou (${t.title}): $e');
      if (_isTransient(e)) {
        // Rede caiu / servidor fora: não conta tentativa; volta para a fila
        // (a cópia atual, na troca, continua) e tenta de novo depois.
        await _deleteQuietly(partial);
        if (!replacing && await _db.track(t.id) != null) {
          await _db.updateTrack(
            t.id,
            const LocalTracksCompanion(
              downloadState: Value(DownloadState.naFila),
            ),
          );
        }
        _retryAt[t.id] = DateTime.now().add(transientRetry);
        _scheduleRetry();
        return;
      }
      if (replacing) {
        // A cópia atual fica; tenta de novo na próxima conferência.
        await _deleteQuietly(partial);
        if (await _db.track(t.id) != null) {
          await _db.updateTrack(
            t.id,
            const LocalTracksCompanion(needsReplace: Value(false)),
          );
        }
        return;
      }
      for (final path in [partial, ?audioPath, ?coverPath]) {
        await _deleteQuietly(path);
      }
      final attempts = t.attempts + 1;
      final giveUp = attempts >= maxAttempts;
      // A faixa pode ter saído de todas as playlists durante o download.
      if (await _db.track(t.id) == null) return;
      await _db.updateTrack(
        t.id,
        LocalTracksCompanion(
          attempts: Value(attempts),
          downloadState: Value(
            giveUp ? DownloadState.falhou : DownloadState.naFila,
          ),
        ),
      );
      if (!giveUp) {
        final wait = retryBase * (1 << (attempts - 1));
        _retryAt[t.id] = DateTime.now().add(wait);
        _scheduleRetry();
      }
    }
  }
}

final downloadManagerProvider =
    NotifierProvider<DownloadManager, DownloadsStatus>(DownloadManager.new);

final networkCheckProvider = Provider<NetworkCheck>(
  (ref) => ConnectivityNetworkCheck(),
);

final downloadPathsProvider = Provider<Future<DownloadPaths> Function()>(
  (ref) => DownloadPaths.appDocuments,
);

/// Estados de download por faixa (`provider:externalId`), para os ícones.
final trackDownloadStatesProvider = StreamProvider<Map<String, DownloadState>>((
  ref,
) {
  final db = ref.watch(localDatabaseProvider);
  return db == null ? Stream.value(const {}) : db.watchStates();
});

/// Progresso de uma playlist baixada.
final playlistDownloadProvider = StreamProvider.autoDispose
    .family<PlaylistDownloadProgress, String>((ref, id) {
      final db = ref.watch(localDatabaseProvider);
      return db == null
          ? Stream.value(PlaylistDownloadProgress.none)
          : db.watchProgress(id);
    });

/// Playlists baixadas (uso offline).
final downloadedPlaylistsProvider = StreamProvider<List<LocalPlaylistRow>>((
  ref,
) {
  final db = ref.watch(localDatabaseProvider);
  return db == null ? Stream.value(const []) : db.watchPlaylists();
});
