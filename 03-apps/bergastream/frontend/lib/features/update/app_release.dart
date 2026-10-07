/// Versão publicada do app no GitHub (tag `bergastream-vX.Y.Z`).
class AppRelease {
  const AppRelease({
    required this.version,
    required this.tag,
    required this.pageUrl,
    required this.notes,
    required this.assets,
  });

  /// Repositório onde o CI publica as versões (público).
  static const repository = 'Agelinena/bergatrix';

  /// Prefixo das tags do Bergastream (o repositório tem outros apps).
  static const tagPrefix = 'bergastream-v';

  /// Arquivo de cada plataforma na release (o CI usa os mesmos nomes).
  static const androidAsset = 'bergastream-android.apk';
  static const linuxAsset = 'bergastream-linux-x64.tar.gz';
  static const windowsAsset = 'bergastream-windows-x64.zip';

  final AppVersion version;
  final String tag;

  /// Página da versão no GitHub ("Ver no GitHub").
  final String pageUrl;
  final String notes;

  /// Nome do arquivo → endereço de download.
  final Map<String, String> assets;

  /// Lê um item de `GET /repos/{repo}/releases`. Nulo se não for uma versão
  /// publicada do Bergastream (outro app, rascunho, pré-lançamento).
  static AppRelease? fromGitHub(Map<String, dynamic> json) {
    final tag = json['tag_name'];
    if (tag is! String || !tag.startsWith(tagPrefix)) return null;
    if (json['draft'] == true || json['prerelease'] == true) return null;
    final version = AppVersion.tryParse(tag.substring(tagPrefix.length));
    if (version == null) return null;
    return AppRelease(
      version: version,
      tag: tag,
      pageUrl: json['html_url'] as String? ?? '',
      notes: (json['body'] as String? ?? '').trim(),
      assets: {
        for (final a in json['assets'] as List? ?? const [])
          if (a case {
            'name': final String name,
            'browser_download_url': final String url,
          })
            name: url,
      },
    );
  }

  /// A versão mais nova do Bergastream numa lista de releases.
  static AppRelease? latestOf(List<dynamic> releases) {
    AppRelease? best;
    for (final item in releases) {
      if (item is! Map<String, dynamic>) continue;
      final release = fromGitHub(item);
      if (release == null) continue;
      if (best == null || release.version > best.version) best = release;
    }
    return best;
  }
}

/// Versão `maior.menor.correção` (o `+build` é ignorado).
class AppVersion implements Comparable<AppVersion> {
  const AppVersion(this.major, this.minor, this.patch);

  final int major;
  final int minor;
  final int patch;

  static AppVersion? tryParse(String text) {
    final core = text.trim().split('+').first.split('-').first;
    final parts = core.split('.');
    if (parts.isEmpty || parts.length > 3) return null;
    final numbers = [for (final p in parts) int.tryParse(p)];
    if (numbers.any((n) => n == null || n < 0)) return null;
    while (numbers.length < 3) {
      numbers.add(0);
    }
    return AppVersion(numbers[0]!, numbers[1]!, numbers[2]!);
  }

  @override
  int compareTo(AppVersion other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    return patch.compareTo(other.patch);
  }

  bool operator >(AppVersion other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) =>
      other is AppVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch);

  @override
  String toString() => '$major.$minor.$patch';
}
