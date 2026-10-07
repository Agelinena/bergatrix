/// Resumo de playlist para a lista da Biblioteca.
class PlaylistSummary {
  const PlaylistSummary({
    required this.id,
    required this.name,
    required this.trackCount,
    required this.peopleCount,
  });

  final String id;
  final String name;
  final int trackCount;

  /// Pessoas com acesso (1 = só você).
  final int peopleCount;
}
