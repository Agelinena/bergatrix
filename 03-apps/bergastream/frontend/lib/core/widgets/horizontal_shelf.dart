import 'package:flutter/material.dart';

import '../theme/berga_colors.dart';
import '../theme/berga_sizes.dart';
import '../theme/berga_text.dart';
import 'cover.dart';

/// Carrossel horizontal de itens de 96 de largura.
class HorizontalShelf extends StatelessWidget {
  const HorizontalShelf({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: BergaSizes.shelfGap,
        children: children,
      ),
    );
  }
}

/// Artista no carrossel: capa circular 96 com o nome embaixo.
class ArtistCircle extends StatelessWidget {
  const ArtistCircle({
    super.key,
    required this.id,
    required this.name,
    this.image,
    this.onTap,
  });

  final String id;
  final String name;
  final ImageProvider? image;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return _ShelfItem(
      cover: Cover(
        seed: id,
        title: name,
        size: BergaSizes.shelfItem,
        circle: true,
        image: image,
      ),
      caption: name,
      onTap: onTap,
    );
  }
}

/// Álbum no carrossel: capa 96 (raio 8) com o nome embaixo.
class AlbumTile extends StatelessWidget {
  const AlbumTile({
    super.key,
    required this.id,
    required this.title,
    this.image,
    this.onTap,
  });

  final String id;
  final String title;
  final ImageProvider? image;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return _ShelfItem(
      cover: Cover(
        seed: id,
        title: title,
        size: BergaSizes.shelfItem,
        image: image,
      ),
      caption: title,
      onTap: onTap,
    );
  }
}

class _ShelfItem extends StatelessWidget {
  const _ShelfItem({required this.cover, required this.caption, this.onTap});

  final Widget cover;
  final String caption;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: BergaSizes.shelfItem,
        child: Column(
          children: [
            cover,
            const SizedBox(height: BergaSizes.shelfCaptionTop),
            Text(
              caption,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: BergaText.secondary.copyWith(
                color: BergaColors.of(context).tx,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
