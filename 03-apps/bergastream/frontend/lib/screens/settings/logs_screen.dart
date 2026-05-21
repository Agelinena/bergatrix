import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/logger.dart';
import '../../core/theme/app_theme.dart';

/// Renders the in-app log buffer ([AppLogger.instance.entries]) as a
/// monospace list, newest first.  Auto-refreshes whenever a new entry
/// is captured.  Provides copy-all and clear actions.
class LogsScreen extends StatefulWidget {
  const LogsScreen({super.key});

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  bool _autoScroll = true;
  bool _reverse = true;  // newest first
  String _filter = '';
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    AppLogger.instance.addListener(_onLogsChanged);
  }

  @override
  void dispose() {
    AppLogger.instance.removeListener(_onLogsChanged);
    _scrollController.dispose();
    super.dispose();
  }

  void _onLogsChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _copyAll(List<LogEntry> entries) {
    final text = entries.map((e) => e.format()).join('\n');
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${entries.length} linhas copiadas'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _clearLogs() {
    AppLogger.instance.clear();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Logs apagados'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final all = AppLogger.instance.entries;
    final filtered = _filter.isEmpty
        ? all
        : all.where((e) => e.message.toLowerCase().contains(_filter.toLowerCase())).toList();
    final shown = _reverse ? filtered.reversed.toList() : filtered;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Logs do app'),
        actions: [
          IconButton(
            icon: const Icon(Icons.content_copy),
            tooltip: 'Copiar todos',
            onPressed: filtered.isEmpty ? null : () => _copyAll(filtered),
          ),
          IconButton(
            icon: Icon(_reverse ? Icons.arrow_downward : Icons.arrow_upward),
            tooltip: _reverse ? 'Mais novos primeiro' : 'Mais antigos primeiro',
            onPressed: () => setState(() => _reverse = !_reverse),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Limpar',
            onPressed: all.isEmpty ? null : _clearLogs,
          ),
        ],
      ),
      body: Column(
        children: [
          // Filter bar
          Padding(
            padding: const EdgeInsets.all(8),
            child: TextField(
              decoration: const InputDecoration(
                hintText: 'Filtrar (ex: AudioPlayer, stream, error)',
                prefixIcon: Icon(Icons.filter_list, size: 20),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _filter = v),
            ),
          ),
          // Status line
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Text(
                  '${filtered.length} / ${all.length} entradas',
                  style: const TextStyle(color: AppColors.textSecondary, fontSize: 11),
                ),
                const Spacer(),
                if (_autoScroll)
                  const Text('● ao vivo',
                      style: TextStyle(color: AppColors.primary, fontSize: 11)),
              ],
            ),
          ),
          const Divider(height: 16),
          // Log list
          Expanded(
            child: shown.isEmpty
                ? const Center(
                    child: Text(
                      'Sem logs ainda',
                      style: TextStyle(color: AppColors.textSecondary),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    itemCount: shown.length,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    itemBuilder: (_, i) {
                      final entry = shown[i];
                      final isError = entry.message.toLowerCase().contains('error') ||
                          entry.message.toLowerCase().contains('failed') ||
                          entry.message.toLowerCase().contains('exception');
                      final isWarn = entry.message.toLowerCase().contains('warning') ||
                          entry.message.toLowerCase().contains('timeout');
                      Color? color;
                      if (isError) {
                        color = AppColors.error;
                      } else if (isWarn) {
                        color = Colors.orange;
                      } else {
                        color = AppColors.textPrimary;
                      }
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: SelectableText(
                          entry.format(),
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11,
                            color: color,
                            height: 1.3,
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
