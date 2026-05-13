import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/app_theme.dart';
import '../../core/api_client.dart';
import '../../models/track.dart';
import '../../widgets/cards/track_card.dart';

class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key});

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  List<Map<String, dynamic>> _history = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final client = ref.read(apiClientProvider);
      final data = await client.getHistory();
      setState(() {
        _history = data.map((e) => e as Map<String, dynamic>).toList();
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Histórico'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _confirmClear(context),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppColors.primary))
          : _history.isEmpty
              ? const Center(child: Text('Nenhuma música ouvida ainda', style: TextStyle(color: AppColors.textSecondary)))
              : RefreshIndicator(
                  onRefresh: _load,
                  color: AppColors.primary,
                  child: ListView.builder(
                    itemCount: _history.length,
                    itemBuilder: (_, i) {
                      final entry = _history[i];
                      final track = Track.fromJson(entry['track'] as Map<String, dynamic>);
                      final playedAt = DateTime.tryParse(entry['played_at'] as String? ?? '');
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (i == 0 || !_sameDay(playedAt, DateTime.tryParse(
                            (_history[i - 1]['played_at'] as String? ?? ''))))
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                              child: Text(
                                _dateLabel(playedAt),
                                style: const TextStyle(color: AppColors.textSecondary, fontWeight: FontWeight.w600, fontSize: 13),
                              ),
                            ),
                          TrackCard(track: track),
                        ],
                      );
                    },
                  ),
                ),
    );
  }

  bool _sameDay(DateTime? a, DateTime? b) {
    if (a == null || b == null) return false;
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  String _dateLabel(DateTime? dt) {
    if (dt == null) return 'Desconhecido';
    final now = DateTime.now();
    if (_sameDay(dt, now)) return 'Hoje';
    if (_sameDay(dt, now.subtract(const Duration(days: 1)))) return 'Ontem';
    return '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year}';
  }

  void _confirmClear(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surfaceVariant,
        title: const Text('Limpar histórico?'),
        content: const Text('Isso não pode ser desfeito.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () async {
              Navigator.pop(context);
              final client = ref.read(apiClientProvider);
              await client.dio.delete('/api/history');
              await _load();
            },
            child: const Text('Limpar'),
          ),
        ],
      ),
    );
  }
}
