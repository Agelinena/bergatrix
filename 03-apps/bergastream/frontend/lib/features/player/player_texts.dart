import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../data/models/search_result.dart';

/// "artista · álbum" (sem o álbum quando vazio).
String artistAndAlbum(SearchResult track) =>
    [track.artist, track.album].where((s) => s.isNotEmpty).join(' · ');

ImageProvider? coverImage(SearchResult track) => imageFor(track.coverUrl);

/// Capa local (`file://`, baixada no aparelho) ou da rede. A UI usa o
/// arquivo local antes da URL (Seção 8.1).
ImageProvider? imageFor(String? url) {
  if (url == null) return null;
  if (url.startsWith('file://')) return FileImage(File.fromUri(Uri.parse(url)));
  return NetworkImage(webImageUrl(url));
}

/// Na web, capas de outras origens passam pelo proxy do servidor (CORS,
/// Seção 9 item 4). O app web é servido pelo mesmo domínio da API.
String webImageUrl(String url, {bool web = kIsWeb}) {
  if (!web || !url.startsWith('https://')) return url;
  return '/api/images?url=${Uri.encodeQueryComponent(url)}';
}
