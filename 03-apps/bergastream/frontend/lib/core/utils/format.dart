/// "3:05" a partir de segundos; "1:02:03" se passar de uma hora.
String formatDuration(int totalSeconds) {
  final hours = totalSeconds ~/ 3600;
  final minutes = totalSeconds % 3600 ~/ 60;
  final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:$seconds';
  }
  return '$minutes:$seconds';
}

/// Duração total legível: "24 min" ou "1 h 05 min".
String totalDuration(Iterable<int> seconds) {
  final total = seconds.fold<int>(0, (a, b) => a + b);
  final minutes = (total / 60).round();
  if (minutes < 60) return '$minutes min';
  return '${minutes ~/ 60} h ${(minutes % 60).toString().padLeft(2, '0')} min';
}

/// Número curto em português: 950, "12,3 mil", "58,7 mi".
String compactCount(int n) {
  String one(double v) => v
      .toStringAsFixed(v >= 100 ? 0 : 1)
      .replaceAll('.', ',')
      .replaceAll(',0', '');
  if (n >= 1000000) return '${one(n / 1000000)} mi';
  if (n >= 1000) return '${one(n / 1000)} mil';
  return '$n';
}

/// Tamanho legível: "350 MB", "1,2 GB".
String formatBytes(int bytes) {
  if (bytes >= 1000000000) {
    return '${(bytes / 1000000000).toStringAsFixed(1).replaceAll('.', ',')} GB';
  }
  return '${(bytes / 1000000).round()} MB';
}
