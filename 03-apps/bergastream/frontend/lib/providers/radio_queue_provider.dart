// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:math';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

  String _savedSource() {
    try {
      return html.window.localStorage[_radioKey] ?? 'lastfm';
    } catch (_) {
      return 'lastfm';
    }
  }

  Future<void> activate(Track seed, [String? source]) async {
    final src = source ?? _savedSource();
    final playerState = ref.read(playerProvider);
    final alreadyQueued = playerState.queue.map((t) => t.id).toSet();

    state = state.copyWith(
      isActive: true,
      seedTrack: seed,
      source: src,
      playedIds: {seed.id},
      queuedIds: alreadyQueued,
      isRefilling: false,
    );

    await _refill();
  }

  void deactivate() {
    state = state.copyWith(isActive: false);
  }

  Future<void> _refill() async {
    if (state.isRefilling) return;
    final seed = state.seedTrack;
    if (seed == null) return;

    state = state.copyWith(isRefilling: true);

    try {
      final playerState = ref.read(playerProvider);
      final remaining = playerState.queue.length - (playerState.queueIndex + 1);
      final needed = max(0, _targetAhead - remaining);
      if (needed == 0) {
        state = state.copyWith(isRefilling: false);
        return;
      }

      final client = ref.read(apiClientProvider);
      final data = await client.getRadioSeeds(seed.id, source: state.source);
      final tracks = (data['tracks'] as List<dynamic>)
          .map((t) => Track.fromJson(t as Map<String, dynamic>))
          .where((t) => !state.playedIds.contains(t.id) && !state.queuedIds.contains(t.id))
          .take(needed)
          .toList();

      final newQueuedIds = {...state.queuedIds, ...tracks.map((t) => t.id)};
      state = state.copyWith(isRefilling: false, queuedIds: newQueuedIds);

      for (final t in tracks) {
        ref.read(playerProvider.notifier).addToQueue(t);
      }
    } catch (_) {
      state = state.copyWith(isRefilling: false);
    }
  }
}
