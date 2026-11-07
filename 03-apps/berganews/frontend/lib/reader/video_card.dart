import 'package:flutter/material.dart';
import 'package:html/dom.dart' as dom;

/// Marca do cartão de vídeo no HTML guardado (backend/app/core/videos.py).
const videoMark = 'berganews:video';

/// O elemento é um cartão de vídeo? Devolve o widget; senão, null.
Widget? videoCardFor(dom.Element element, void Function(String url) open) {
  if (element.localName != 'a' || element.attributes['title'] != videoMark) {
    return null;
  }
  final href = element.attributes['href'] ?? '';
  final img = element.querySelector('img');
  final label = (img?.attributes['alt'] ?? element.text).replaceFirst('▶', '').trim();
  return VideoCard(
    thumbnail: img?.attributes['src'],
    label: label.isEmpty ? 'Vídeo' : label,
    onTap: href.isEmpty ? null : () => open(href),
  );
}

/// Miniatura com o botão de play; toca no player do veículo (Globoplay,
/// YouTube…), que é onde o vídeo está.
class VideoCard extends StatelessWidget {
  const VideoCard({super.key, required this.label, this.thumbnail, this.onTap});

  final String label;
  final String? thumbnail;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Material(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AspectRatio(
                aspectRatio: 16 / 9,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (thumbnail != null)
                      Image.network(
                        thumbnail!,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                    const DecoratedBox(
                      decoration: BoxDecoration(color: Color(0x55000000)),
                    ),
                    Center(
                      child: Container(
                        width: 64,
                        height: 64,
                        decoration: const BoxDecoration(
                          color: Color(0xCC000000),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.play_arrow, color: Colors.white, size: 40),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                child: Row(
                  children: [
                    Icon(Icons.smart_display_outlined, size: 18, color: scheme.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                    Icon(Icons.open_in_new, size: 16, color: scheme.onSurfaceVariant),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
