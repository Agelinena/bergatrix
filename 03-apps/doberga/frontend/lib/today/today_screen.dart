import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/session.dart';
import '../core/widgets.dart';
import '../sync/sync_badge.dart';

/// Um item que um módulo mostra no "Hoje" ou na "Semana".
class AgendaItem {
  const AgendaItem({
    required this.title,
    required this.date,
    required this.icon,
    this.subtitle,
    this.overdue = false,
    this.onTap,
  });

  final String title;
  final String? subtitle;
  final DateTime date;
  final IconData icon;
  final bool overdue;
  final VoidCallback? onTap;
}

/// Cada módulo fornece os itens de um intervalo de datas, lidos do banco
/// local (funciona offline). Os módulos entram aqui conforme as fases:
/// recorrentes, calendário, compras.
final agendaSourcesProvider = Provider<List<List<AgendaItem> Function(Ref ref, DateTime from, DateTime to)>>(
  (ref) => const [],
);

final agendaProvider = Provider.family<List<AgendaItem>, (DateTime, DateTime)>((ref, range) {
  final items = [
    for (final source in ref.watch(agendaSourcesProvider)) ...source(ref, range.$1, range.$2),
  ]..sort((a, b) => a.date.compareTo(b.date));
  return items;
});

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

class TodayScreen extends ConsumerStatefulWidget {
  const TodayScreen({super.key});

  @override
  ConsumerState<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends ConsumerState<TodayScreen> {
  bool _week = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = ref.watch(sessionProvider.select((s) => s.user?.name)) ?? '';
    final today = _day(DateTime.now());
    final end = today.add(Duration(days: _week ? 7 : 1));
    final items = ref.watch(agendaProvider((today, end)));
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(_greeting(name), style: theme.textTheme.headlineSmall),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(_longDate(today),
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ),
        const SyncNoticesBanner(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Coisas pra hoje'), icon: Icon(Icons.today)),
              ButtonSegment(value: true, label: Text('Pra semana'), icon: Icon(Icons.date_range)),
            ],
            selected: {_week},
            onSelectionChanged: (v) => setState(() => _week = v.first),
          ),
        ),
        if (items.isEmpty)
          SizedBox(
            height: 320,
            child: MessageView(
              icon: Icons.wb_sunny_outlined,
              title: _week ? 'Semana livre' : 'Nada pra hoje',
              message: 'Recorrentes, eventos e compras aparecem aqui conforme os módulos chegarem.',
            ),
          )
        else
          for (final item in items)
            ListTile(
              leading: Icon(item.icon, color: item.overdue ? theme.colorScheme.error : null),
              title: Text(item.title),
              subtitle: item.subtitle == null ? null : Text(item.subtitle!),
              trailing: _week ? Text(_shortDate(item.date)) : null,
              onTap: item.onTap,
            ),
      ],
    );
  }

  static String _greeting(String name) {
    final hour = DateTime.now().hour;
    final hello = hour < 12 ? 'Bom dia' : (hour < 18 ? 'Boa tarde' : 'Boa noite');
    final first = name.split(' ').first;
    return first.isEmpty ? hello : '$hello, $first';
  }
}

const _weekdays = ['segunda', 'terça', 'quarta', 'quinta', 'sexta', 'sábado', 'domingo'];
const _months = [
  'janeiro', 'fevereiro', 'março', 'abril', 'maio', 'junho',
  'julho', 'agosto', 'setembro', 'outubro', 'novembro', 'dezembro',
];

String _longDate(DateTime d) =>
    '${_weekdays[d.weekday - 1]}, ${d.day} de ${_months[d.month - 1]}';

String _shortDate(DateTime d) => '${_weekdays[d.weekday - 1].substring(0, 3)} ${d.day}';
