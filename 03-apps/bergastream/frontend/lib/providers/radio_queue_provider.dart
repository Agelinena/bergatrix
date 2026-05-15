import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/storage.dart';
import '../models/track.dart';
import '../core/api_client.dart';
import 'player_provider.dart';

class RadioQueueState {
  final bool isActive;
  final Track? seedTrack;
  final String source;
  final Set<String> playedIds;
  final Set<String> queuedIds;
  final bool isRefilling;

  const RadioQueueState({
    required this.isActive,
    required this.seedTrack,
    required this.source,
    required this.playedIds,
    required this.queuedIds,
    required this.isRefilling,
  });

  factory RadioQueueState.initial() => const RadioQueueState(
    isActive: false,
    seedTrack: null,
    source: 'lastfm',
    playedIds: <String>{},
    queuedIds: <String>{},
    isRefilling: false,
  );

  RadioQueueState copyWith({
    bool? isActive,
    Track? seedTrack,
    String? source,
    Set<String>? playedIds,
    Set<String>? queuedIds,
    bool? isRefilling,
  }) => RadioQueueState(
    isActive: isActive ?? this.isActive,
    seedTrack: seedTrack ?? this.seedTrack,
    source: source ?? this.source,
    playedIds: playedIds ?? this.playedIds,
    queuedIds: queuedIds ?? this.queuedIds,
    isRefilling: isRefilling ?? this.isRefilling,
  );
}

final radioQueueProvider = NotifierProvider<RadioQueueNotifier, RadioQueueState>(
  RadioQueueNotifier.new,
);

class RadioQueueNotifier extends Notifier<RadioQueueState> {
  static const _minAhead = 5;
  static const _targetAhead = 20;
  static const _radioKey = 'radio_source';

  /// Flag síncrona para evitar _refill() duplo no mesmo frame.
  bool _refillInFlight = false;

  /// Contador de geração para cancel de activate() em voo.
  /// Quando o usuário troca de música antes de activate() terminar, o ID muda
  /// e a resposta stale é descartada antes de adicionar tracks à fila.
  int _activationId = 0;

  @override
  RadioQueueState build() {
    ref.listen<PlayerState>(playerProvider, (prev, next) {
      if (!state.isActive) return;

      final curr = next.currentTrack;
      final prevCurr = prev?.currentTrack;

      if (curr != null && curr.id != prevCurr?.id) {
        state = state.copyWith(
          playedIds: {...state.playedIds, curr.id},
          seedTrack: curr,
        );
      }

      final remaining = next.queue.length - (next.queueIndex + 1);
      if (remaining < _minAhead && !state.isRefilling) {
        _refill();
      }
    });
    return RadioQueueState.initial();
  }

  Future<String> _savedSource() async {
    try {
      return await AppStorage.getString(_radioKey) ?? 'lastfm';
    } catch (_) {
      return 'lastfm';
    }
  }

  Future<void> activate(Track seed, [String? source]) async {
    // Snapshot do ID ANTES do await — se deactivate() ou outro activate()
    // for chamado enquanto aguardamos a API, myId ≠ _activationId e descartamos.
    final myId = ++_activationId;

    final src = source ?? await _savedSource();
    final playerState = ref.read(playerProvider);
    final alreadyQueued = playerState.queue.map((t) => t.id).toSet();

    state = state.copyWith(
      isActive: true,
      seedTrack: seed,
      source: src,
      playedIds: {seed.id},
      queuedIds: alreadyQueued,
      isRefilling: true,
    );

    var tracksAdded = 0;
    try {
      final client = ref.read(apiClientProvider);
      final data = await client.getRadioSeeds(
        seed.id,
        source: src,
        title: seed.title,
        artist: seed.artist,
      );

      // Se o usuário trocou de música enquanto buscávamos, descarta o resultado.
      if (_activationId != myId) {
        debugPrint('[RadioQueue] activate: resultado stale (id=$myId), descartando');
        return;
      }

      final tracks = (data['tracks'] as List<dynamic>)
          .map((t) => Track.fromJson(t as Map<String, dynamic>))
          .where((t) => !state.playedIds.contains(t.id) && !state.queuedIds.contains(t.id))
          .take(_targetAhead)
          .toList();

      final newQueuedIds = {...state.queuedIds, ...tracks.map((t) => t.id)};
      state = state.copyWith(queuedIds: newQueuedIds);

      for (final t in tracks) {
        ref.read(playerProvider.notifier).addToQueue(t);
      }
      tracksAdded = tracks.length;
      if (tracks.isNotEmpty) {
        client.prefetchTracks(tracks.map((t) => t.id).toList());
      }
      debugPrint('[RadioQueue] activate: added ${tracks.length} tracks for "${seed.title}"');
    } catch (e, st) {
      debugPrint('[RadioQueue] activate error: $e\n$st');
    } finally {
      if (_activationId == myId) {
        state = state.copyWith(isRefilling: false);
      }
    }

    // Faixa em cache pode terminar ANTES de activate() completar:
    // Se o player ficou idle, avança agora que as seeds chegaram.
    if (tracksAdded > 0 && _activationId == myId) {
      final ps = ref.read(playerProvider);
      if (ps.hasTrack && ps.status == PlayerStatus.idle) {
        debugPrint('[RadioQueue] activate: player travado em idle, avançando');
        await ref.read(playerProvider.notifier).next();
      }
    }
  }

  void deactivate() {
    _activationId++; // Cancela qualquer activate() ainda em voo
    state = state.copyWith(isActive: false);
  }

  Future<void> _refill() async {
    // _refillInFlight é verificado PRIMEIRO (síncrono) para evitar que dois
    // disparos do listener no mesmo frame passem ambos pelo check de isRefilling
    // (que só se propaga após o microtask de state notification).
    if (_refillInFlight || state.isRefilling) return;
    _refillInFlight = true;   // lock síncrono imediato
    final seed = state.seedTrack;
    if (seed == null) {
      _refillInFlight = false;
      return;
    }

    state = state.copyWith(isRefilling: true);

    var tracksAdded = 0;
    try {
      final playerState = ref.read(playerProvider);
      final remaining = playerState.queue.length - (playerState.queueIndex + 1);
      final needed = max(0, _targetAhead - remaining);
      if (needed == 0) {
        state = state.copyWith(isRefilling: false);
        return;
      }

      final client = ref.read(apiClientProvider);
      final data = await client.getRadioSeeds(
        seed.id,
        source: state.source,
        title: seed.title,
        artist: seed.artist,
      );
      final tracks = (data['tracks'] as List<dynamic>)
          .map((t) => Track.fromJson(t as Map<String, dynamic>))
          .where((t) => !state.playedIds.contains(t.id) && !state.queuedIds.contains(t.id))
          .take(needed)
          .toList();

      final newQueuedIds = {...state.queuedIds, ...tracks.map((t) => t.id)};
      // Update queuedIds but keep isRefilling=true until addToQueue calls finish.
      // Each addToQueue triggers the playerProvider listener; if isRefilling were
      // already false at that point the listener would fire _refill() again
      // immediately (remaining < 5 after first add), causing a duplicate fetch.
      state = state.copyWith(queuedIds: newQueuedIds);

      for (final t in tracks) {
        ref.read(playerProvider.notifier).addToQueue(t);
      }
      tracksAdded = tracks.length;
      if (tracks.isNotEmpty) {
        client.prefetchTracks(tracks.map((t) => t.id).toList());
      }

      // Only unlock after the loop — listener will now see the full remaining count
      state = state.copyWith(isRefilling: false);
    } catch (e, st) {
      debugPrint('[RadioQueue] _refill error: $e\n$st');
    } finally {
      _refillInFlight = false;
      state = state.copyWith(isRefilling: false);
    }

    // Se o player ficou idle enquanto esperávamos pela request (remaining chegou a 0
    // e _handleTrackComplete foi chamado antes de termos tracks), avançamos agora.
    if (tracksAdded > 0) {
      final ps = ref.read(playerProvider);
      if (ps.hasTrack && ps.status == PlayerStatus.idle) {
        debugPrint('[RadioQueue] _refill: player travado em idle, avançando');
        await ref.read(playerProvider.notifier).next();
      }
    }
  }
}
