import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/app_platform.dart';
import '../../core/storage/key_value_store.dart';
import '../models/search_result.dart';

/// O que foi aberto a partir da busca.
enum RecentKind { track, artist, album, playlist }

/// Item das "Buscas recentes" (como no Spotify): a música, o artista, o
/// álbum ou a playlist em que a pessoa tocou — não o texto digitado.
class RecentItem {
  const RecentItem({
    required this.kind,
    required this.provider,
    required this.externalId,
    required this.title,
    required this.subtitle,
    this.imageUrl,
    this.url,
    this.track,
  });

  factory RecentItem.fromJson(Map<String, dynamic> json) => RecentItem(
    kind: RecentKind.values.byName(json['kind'] as String),
    provider: json['provider'] as String? ?? '',
    externalId: json['external_id'] as String? ?? '',
    title: json['title'] as String? ?? '',
    subtitle: json['subtitle'] as String? ?? '',
    imageUrl: json['image_url'] as String?,
    url: json['url'] as String?,
    track: json['track'] == null
        ? null
        : SearchResult.fromJson(json['track'] as Map<String, dynamic>),
  );

  final RecentKind kind;
  final String provider;
  final String externalId;
  final String title;
  final String subtitle;
  final String? imageUrl;

  /// Playlist de outra origem: o link (abre a playlist importada).
  final String? url;

  /// Música: a faixa inteira (para tocar e para o menu ⋮).
  final SearchResult? track;

  /// Mesma coisa aberta de novo sobe para o topo (sem repetir).
  String get key => '${kind.name}:$provider:${url ?? externalId}';

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'provider': provider,
    'external_id': externalId,
    'title': title,
    'subtitle': subtitle,
    'image_url': ?imageUrl,
    'url': ?url,
    'track': ?track?.toJson(),
  };
}

/// "Buscas recentes": mais recentes primeiro, sem repetir, no máximo
/// [limit]. Fica no armazenamento do aparelho.
class SearchHistory extends Notifier<List<RecentItem>> {
  static const limit = 20;

  String get _key =>
      '${ref.read(appPlatformProvider).simulated ? 'sim_android.' : ''}search_recent';

  KeyValueStore get _store => ref.read(keyValueStoreProvider);

  /// Leitura do que estava guardado: quem muda a lista espera por ela
  /// (senão, um item adicionado logo ao abrir apagava os guardados).
  late Future<void> _loaded;

  @override
  List<RecentItem> build() {
    _loaded = _load();
    return const [];
  }

  Future<void> _load() async {
    final raw = await _store.read(_key);
    if (raw == null || !ref.mounted) return;
    try {
      state = [
        for (final item in jsonDecode(raw) as List<dynamic>)
          RecentItem.fromJson(item as Map<String, dynamic>),
      ];
    } on Object {
      state = const [];
    }
  }

  Future<void> add(RecentItem item) async {
    await _loaded;
    state = [
      item,
      for (final i in state)
        if (i.key != item.key) i,
    ].take(limit).toList();
    await _save();
  }

  Future<void> remove(RecentItem item) async {
    await _loaded;
    state = [
      for (final i in state)
        if (i.key != item.key) i,
    ];
    await _save();
  }

  Future<void> clear() async {
    await _loaded;
    state = const [];
    await _save();
  }

  Future<void> _save() =>
      _store.write(_key, jsonEncode([for (final i in state) i.toJson()]));
}

final searchHistoryProvider = NotifierProvider<SearchHistory, List<RecentItem>>(
  SearchHistory.new,
);
