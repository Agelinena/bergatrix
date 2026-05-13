import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/app_theme.dart';
import '../../core/api_client.dart';
import '../../models/track.dart';
import '../../providers/player_provider.dart';
import '../../widgets/cards/track_card.dart';

class RadioScreen extends ConsumerStatefulWidget {
  final Track seedTrack;
  // When false, seeds are added to the existing queue instead of starting fresh play
  final bool autoPlay;
  const RadioScreen({super.key, required this.seedTrack, this.autoPlay = true});

  @override
  ConsumerState<RadioScreen> createState() => _RadioScreenState();
}

class _RadioScreenState extends ConsumerState<RadioScreen> {
  String _source = 'deezer';
  List<Track> _queue = [];
  bool _loading = false;
  int _loadMoreAttempts = 0;
  static const _maxLoadMoreAttempts = 2;

  static const _sources = ['deezer', 'spotify', 'ai'];
  static const _sourceLabels = ['Deezer', 'Spotify', 'IA (Gemini)'];

  @override
  void initState() {
    super.initState();
    _loadSeeds();
  }

  Future<void> _loadSeeds() async {
    setState(() { _loading = true; _loadMoreAttempts = 0; });
    try {
      final client = ref.read(apiClientProvider);
      final data = await client.getRadioSeeds(widget.seedTrack.id, source: _source);
      final tracks = (data['tracks'] as List<dynamic>)
          .map((t) => Track.fromJson(t as Map<String, dynamic>))
          .toList();
      setState(() { _queue = tracks; _loading = false; });

      if (tracks.isNotEmpty) {
        if (widget.autoPlay) {
          // Start fresh playback from radio seeds
          ref.read(playerProvider.notifier).play(tracks.first, queue: tracks);
        } else {
          // Add seeds to the existing queue (track already playing)
          for (final t in tracks) ref.read(playerProvider.notifier).addToQueue(t);
        }
        client.prefetchTracks(tracks.map((t) => t.id).toList());
      }
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  Future<void> _loadMore() async {
    if (_queue.length > 3 || _loading || _loadMoreAttempts >= _maxLoadMoreAttempts) return;
    setState(() => _loading = true);
    try {
      final client = ref.read(apiClientProvider);
      final data = await client.getRadioSeeds(widget.seedTrack.id, source: _source);
      final more = (data['tracks'] as List<dynamic>)
          .map((t) => Track.fromJson(t as Map<String, dynamic>))
          .toList();
      if (more.isEmpty) {
        _loadMoreAttempts++;
      } else {
        _loadMoreAttempts = 0;
      }
      setState(() { _queue.addAll(more); _loading = false; });
      for (final t in more) ref.read(playerProvider.notifier).addToQueue(t);
    } catch (_) {
      _loadMoreAttempts++;
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentTrack = ref.watch(playerProvider).currentTrack;
    if (_queue.length < 3 && !_loading && _loadMoreAttempts < _maxLoadMoreAttempts) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadMore());
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Modo Rádio'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loadSeeds),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: SizedBox(
            height: 44,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              itemCount: _sources.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (_, i) => FilterChip(
                label: Text(_sourceLabels[i]),
                selected: _source == _sources[i],
                onSelected: (_) {
                  setState(() => _source = _sources[i]);
                  _loadSeeds();
                },
                selectedColor: AppColors.primary.withOpacity(0.2),
                checkmarkColor: AppColors.primary,
              ),
            ),
          ),
        ),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Seed track header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('Baseado em:', style: Theme.of(context).textTheme.bodyMedium),
          ),
          TrackCard(track: widget.seedTrack),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text('Próximas músicas', style: Theme.of(context).textTheme.titleSmall),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(color: AppColors.primary))
                : _queue.isEmpty
                    ? const Center(child: Text('Nenhuma sugestão disponível', style: TextStyle(color: AppColors.textSecondary)))
                    : ListView.builder(
                        itemCount: _queue.length,
                        itemBuilder: (_, i) {
                          final track = _queue[i];
                          final isCurrent = currentTrack?.id == track.id;
                          return TrackCard(
                            track: track,
                            queue: _queue,
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
