/// Faixa de música. A serialização JSON entra no Passo 4.
class Track {
  const Track({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.durationSeconds,
  });

  final String id;
  final String title;
  final String artist;
  final String album;
  final int durationSeconds;
}
