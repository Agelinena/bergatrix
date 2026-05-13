import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/app_theme.dart';
import '../../core/api_client.dart';
import '../../models/track.dart';
import '../../providers/player_provider.dart';
import '../../widgets/cards/track_card.dart';

class RadioScreen extends ConsumerStatefulWidget {
  final Track seedTrack;
  final bool autoPlay;
  const RadioScreen({super.key, required this.seedTrack, this.autoPlay = true});

  @override
  ConsumerState<RadioScreen> createState() => _RadioScreenState();
}

class _RadioScreenState extends ConsumerState<RadioScreen> {
  String _source = 'deezer';
  List<Track> _queue = [];
  bool _loading = false;
  String? _error;
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
    setState(() { _loading = true; _error = null; _loadMoreAttempts = 0; });
    try {
      final client = ref.read(apiClientProvider);
      // Register ensures the track exists in DB so the backend can resolve title/artist.
      try { await client.registerTrack(widget.seedTrack.toJson()); } catch (_) {}
      final data = await client.getRadioSeeds(widget.seedTrack.id, source: _source);
      final tracks = (data['tracks'] as List<dynamic>)
          .map((t) => Track.fromJson(t as Map<String, dynamic>))
          .toList();
      if (!mounted) return;
      setState(() { _queue = tracks; _loading = false; });

      if (tracks.isNotEmpty) {
        if (widget.autoPlay) {
          ref.read(playerProvider.notifier).play(tracks.first, queue: tracks);
        } else {
          for (final t in tracks) ref.read(playerProvider.notifier).addToQueue(t);
        }
        client.prefetchTracks(tracks.map((t) => t.id).toList());
      }
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = e.toString(); });
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
      if (!mounted) return;
      setState(() {
        _loadMoreAttempts = more.isEmpty ? _loadMoreAttempts + 1 : 0;
        _queue.addAll(more);
        _loading = false;
      });
      for (final t in more) ref.read(playerProvider.notifier).addToQueue(t);
    } catch (e) {
      if (mounted) setState(() { _loadMoreAttempts++; _loading = false; });
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
                : _error != null
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.wifi_off, color: AppColors.textSecondary, size: 40),
                            const SizedBox(height: 8),
                            const Text('Erro ao carregar sugestões', style: TextStyle(color: AppColors.textSecondary)),
                            const SizedBox(height: 4),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 32),
                              child: Text(_error!, style: const TextStyle(color: AppColors.error, fontSize: 11), textAlign: TextAlign.center),
                            ),
                            const SizedBox(height: 12),
                            TextButton(onPressed: _loadSeeds, child: const Text('Tentar novamente')),
                          ],
                        ),
                      )
                    : _queue.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Text('Nenhuma sugestão disponível', style: TextStyle(color: AppColors.textSecondary)),
                                const SizedBox(height: 12),
                                TextButton(onPressed: _loadSeeds, child: const Text('Tentar novamente')),
                              ],
                            ),
                          )
                        : ListView.builder(
                            itemCount: _queue.length,
                            itemBuilder: (_, i) => TrackCard(
                              track: _queue[i],
                              queue: _queue,
                            ),
                          ),
          ),
        ],
      ),
    );
  }
}
