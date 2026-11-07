// Datas e nomes em português, sem pacote de internacionalização.

const _months = [
  'jan', 'fev', 'mar', 'abr', 'mai', 'jun',
  'jul', 'ago', 'set', 'out', 'nov', 'dez',
];

String _two(int n) => n.toString().padLeft(2, '0');

/// "agora", "há 5 min", "há 3 h", "ontem, 14:05", "12 out, 09:30", "12 out 2025".
String relativeTime(DateTime when, {DateTime? now}) {
  final current = now ?? DateTime.now();
  final diff = current.difference(when);
  if (diff.inMinutes < 1) return 'agora';
  if (diff.inMinutes < 60) return 'há ${diff.inMinutes} min';
  if (diff.inHours < 12) return 'há ${diff.inHours} h';
  final today = DateTime(current.year, current.month, current.day);
  final day = DateTime(when.year, when.month, when.day);
  final clock = '${_two(when.hour)}:${_two(when.minute)}';
  if (day == today) return 'hoje, $clock';
  if (today.difference(day).inDays == 1) return 'ontem, $clock';
  final date = '${when.day} ${_months[when.month - 1]}';
  if (when.year == current.year) return '$date, $clock';
  return '$date ${when.year}';
}

/// "12 out, 09:30" (linha do tempo).
String shortDateTime(DateTime when) =>
    '${when.day} ${_months[when.month - 1]}, ${_two(when.hour)}:${_two(when.minute)}';

const languageNames = {
  'pt': 'português',
  'en': 'inglês',
  'es': 'espanhol',
  'fr': 'francês',
  'de': 'alemão',
  'it': 'italiano',
};

String languageName(String? code) => languageNames[code] ?? (code ?? '?');

/// "1 veículo", "3 veículos".
String plural(int n, String one, String many) => '$n ${n == 1 ? one : many}';
