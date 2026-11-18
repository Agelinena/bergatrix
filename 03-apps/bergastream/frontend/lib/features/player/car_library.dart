import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/playlist_models.dart';
import '../../data/models/search_result.dart';
import '../../data/repositories/search_repository.dart';
import '../auth/session.dart';
import '../playlists/playlist_store.dart';
import 'media_notification.dart';
import 'player_controller.dart';

/// Android Auto (e outros "navegadores de mídia" do Android): o que aparece
/// no painel do carro e o que tocar. Playlists → músicas; busca por voz
/// começa a rádio da música; a fila atual aparece como fila.
class CarLibrary {
  CarLibrary(this._ref);

  final Ref _ref;

  static const playlists = 'playlists';
  static const _playlistPrefix = 'playlist:';
  static const _trackPrefix = 'track:';

  /// Ordem da fila mostrada no carro (índice → uid do player).
  List<int> _queueUids = const [];

  Future<List<MediaItem>> children(String parentId) async {
    try {
      if (parentId == AudioService.browsableRootId) {
        return const [
          MediaItem(id: playlists, title: 'Playlists', playable: false),
        ];
      }
      if (parentId == AudioService.recentRootId) return _recent();
      if (parentId == playlists) {
        final list = await _ref.read(myPlaylistsProvider.future);
        return [for (final p in list) _playlistItem(p)];
      }
      if (parentId.startsWith(_playlistPrefix)) {
        final id = parentId.substring(_playlistPrefix.length);
        final detail = await _ref.read(playlistDetailProvider(id).future);
        return [
          for (final (i, t) in detail.tracks.indexed)
            _trackItem(t.asResult, '$_trackPrefix$id:$i'),
        ];
      }
    } on Object catch (e) {
      debugPrint('Android Auto: $e');
    }
    return const [];
  }

  /// "Continuar ouvindo": a música atual.
  List<MediaItem> _recent() {
    final current = _ref.read(playerProvider).current;
    if (current == null) return const [];
    return [_trackItem(current.track, 'queue:${current.uid}')];
  }

  MediaItem _playlistItem(ServerPlaylist p) => MediaItem(
    id: '$_playlistPrefix${p.id}',
    title: p.name,
    artist: '${p.trackCount} músicas',
    playable: false,
    artUri: _absolute(p.coverUrl),
  );

  MediaItem _trackItem(SearchResult t, String id) => MediaItem(
    id: id,
    title: t.title,
    artist: t.artist,
    album: t.album,
    duration: t.durationSeconds > 0
        ? Duration(seconds: t.durationSeconds)
        : null,
    artUri: _absolute(t.coverUrl),
    playable: true,
  );

  /// Capa das playlists vem como caminho do servidor ("/api/playlists/…").
  Uri? _absolute(String? url) {
    if (url == null) return null;
    if (url.startsWith('http')) return Uri.tryParse(url);
    final server = _ref.read(sessionProvider).server;
    return server == null ? null : Uri.tryParse('$server$url');
  }

  Future<void> play(String mediaId) async {
    final player = _ref.read(playerProvider.notifier);
    if (mediaId.startsWith('queue:')) {
      final uid = int.tryParse(mediaId.substring(6));
      if (uid != null) await player.jumpTo(uid);
      return;
    }
    String? playlistId;
    var index = 0;
    if (mediaId.startsWith(_trackPrefix)) {
      final rest = mediaId.substring(_trackPrefix.length);
      final cut = rest.lastIndexOf(':');
      playlistId = rest.substring(0, cut);
      index = int.tryParse(rest.substring(cut + 1)) ?? 0;
    } else if (mediaId.startsWith(_playlistPrefix)) {
      playlistId = mediaId.substring(_playlistPrefix.length);
    }
    if (playlistId == null) return;
    final detail = await _ref.read(playlistDetailProvider(playlistId).future);
    if (detail.tracks.isEmpty) return;
    await player.playList(
      [for (final t in detail.tracks) t.asResult],
      index.clamp(0, detail.tracks.length - 1),
      context: detail.name,
      playlistId: detail.id,
    );
  }

  /// "Ok Google, tocar Lonely Day no Bergastream": toca a primeira que achar
  /// e monta a rádio dela. Sem texto: continua o que estava tocando.
  Future<void> search(String query) async {
    final player = _ref.read(playerProvider.notifier);
    if (query.trim().isEmpty) {
      if (!_ref.read(playerProvider).isPlaying) await player.togglePlay();
      return;
    }
    try {
      final found = await _ref
          .read(searchRepositoryProvider)
          .search(query.trim(), SearchSource.deezer);
      if (found.tracks.isNotEmpty) await player.startRadio(found.tracks.first);
    } on Object catch (e) {
      debugPrint('Busca do carro: $e');
    }
  }

  /// Fila do carro: a sua fila e as próximas da lista (até 30).
  List<MediaItem> queueOf(PlayerState state) {
    final items = [...state.manual, ...state.upNext].take(30).toList();
    _queueUids = [for (final i in items) i.uid];
    return [for (final i in items) _trackItem(i.track, 'queue:${i.uid}')];
  }

  Future<void> skipToQueueItem(int index) async {
    if (index < 0 || index >= _queueUids.length) return;
    await _ref.read(playerProvider.notifier).jumpTo(_queueUids[index]);
  }
}

/// Liga a biblioteca do carro ao serviço de mídia (só no app Android; nulo
/// onde não há serviço). Lido uma vez ao abrir o app.
final carLibraryProvider = Provider<CarLibrary?>((ref) {
  final handler = ref.watch(mediaNotificationProvider);
  if (handler == null) return null;
  final library = CarLibrary(ref);
  handler.library = library;
  ref.listen(
    playerProvider.select(
      (s) => (s.current?.uid, s.manual.length, s.upNext.length),
    ),
    (_, _) => handler.queue.add(library.queueOf(ref.read(playerProvider))),
  );
  ref.onDispose(() => handler.library = null);
  return library;
});
