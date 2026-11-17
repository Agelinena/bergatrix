import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/theme/berga_colors.dart';
import '../../core/theme/berga_sizes.dart';
import '../../core/theme/berga_text.dart';
import '../../core/widgets/widgets.dart';

/// Resultado do editor: os bytes e o tipo (a foto inteira mantém o original).
class EditedCover {
  const EditedCover(
    this.bytes, {
    required this.mimeType,
    required this.filename,
  });

  final Uint8List bytes;
  final String mimeType;
  final String filename;
}

/// Abre o editor da foto da playlist: arrastar e dar zoom (pinça, roda do
/// mouse ou o controle), girar e escolher entre recortar o quadrado ou usar a
/// foto inteira. Nulo = cancelou.
Future<EditedCover?> showCoverEditor(
  BuildContext context,
  Uint8List bytes, {
  required String mimeType,
  required String filename,
}) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  if (!context.mounted) return null;
  return showDialog<EditedCover>(
    context: context,
    builder: (_) => CoverEditor(
      image: frame.image,
      original: EditedCover(bytes, mimeType: mimeType, filename: filename),
    ),
  );
}

class CoverEditor extends StatefulWidget {
  const CoverEditor({super.key, required this.image, required this.original});

  final ui.Image image;
  final EditedCover original;

  /// Lado da foto recortada.
  static const outputSize = 1000;

  @override
  State<CoverEditor> createState() => _CoverEditorState();
}

class _CoverEditorState extends State<CoverEditor> {
  late ui.Image _image = widget.image;
  final _transform = TransformationController();
  int _turns = 0;
  double _viewport = 300;
  bool _saving = false;

  /// Escala em que a foto cobre o quadrado (zoom 1 do controle).
  double get _base => _viewport / math.min(_image.width, _image.height);

  double get _zoom => _transform.value.getMaxScaleOnAxis();

  @override
  void initState() {
    super.initState();
    _transform.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  /// Começa centralizada (o meio da foto no meio do quadrado).
  void _center() {
    final w = _image.width * _base;
    final h = _image.height * _base;
    _transform.value = Matrix4.identity()
      ..translateByDouble((_viewport - w) / 2, (_viewport - h) / 2, 0, 1);
  }

  void _setZoom(double zoom) {
    // Zoom em torno do centro do quadrado.
    final current = _zoom;
    final f = zoom / current;
    final c = _viewport / 2;
    _transform.value = Matrix4.identity()
      ..translateByDouble(c, c, 0, 1)
      ..scaleByDouble(f, f, 1, 1)
      ..translateByDouble(-c, -c, 0, 1)
      ..multiply(_transform.value);
  }

  Future<void> _rotate() async {
    final src = _image;
    final recorder = ui.PictureRecorder();
    Canvas(recorder)
      ..translate(src.height.toDouble(), 0)
      ..rotate(math.pi / 2)
      ..drawImage(
        src,
        Offset.zero,
        Paint()..filterQuality = FilterQuality.high,
      );
    final rotated = await recorder.endRecording().toImage(
      src.height,
      src.width,
    );
    setState(() {
      _image = rotated;
      _turns = (_turns + 1) % 4;
    });
    _center();
  }

  /// A parte da foto que está no quadrado, em pixels da foto.
  Rect _cropRect() {
    final m = _transform.value;
    final scale = m.getMaxScaleOnAxis() * _base;
    final t = m.getTranslation();
    final left = -t.x / scale;
    final top = -t.y / scale;
    final side = _viewport / scale;
    return Rect.fromLTWH(left, top, side, side).intersect(
      Rect.fromLTWH(0, 0, _image.width.toDouble(), _image.height.toDouble()),
    );
  }

  Future<void> _save({required bool crop}) async {
    if (!crop && _turns == 0) {
      Navigator.pop(context, widget.original);
      return;
    }
    setState(() => _saving = true);
    final src = crop
        ? _cropRect()
        : Rect.fromLTWH(
            0,
            0,
            _image.width.toDouble(),
            _image.height.toDouble(),
          );
    final longest = math.max(src.width, src.height);
    final scale = math.min(1.0, CoverEditor.outputSize / longest);
    final w = math.max(1, (src.width * scale).round());
    final h = math.max(1, (src.height * scale).round());
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawImageRect(
      _image,
      src,
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint()..filterQuality = FilterQuality.high,
    );
    final out = await recorder.endRecording().toImage(w, h);
    final data = await out.toByteData(format: ui.ImageByteFormat.png);
    if (!mounted) return;
    if (data == null) {
      setState(() => _saving = false);
      return;
    }
    Navigator.pop(
      context,
      EditedCover(
        data.buffer.asUint8List(),
        mimeType: 'image/png',
        filename: 'capa.png',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = BergaColors.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final viewport = math.min(width - 72, 360.0).clamp(160.0, 360.0);
    if (viewport != _viewport) {
      _viewport = viewport;
      WidgetsBinding.instance.addPostFrameCallback((_) => _center());
    }
    final zoom = _zoom.clamp(1.0, 5.0);
    return Dialog(
      backgroundColor: c.bg,
      insetPadding: const EdgeInsets.all(20),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Foto da playlist', style: BergaText.h2.copyWith(color: c.tx)),
            const SizedBox(height: 4),
            Text(
              'Arraste e dê zoom para escolher o quadrado, ou use a foto inteira.',
              style: BergaText.secondary.copyWith(color: c.mu),
            ),
            const SizedBox(height: 14),
            Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(BergaSizes.coverRadius),
                child: SizedBox.square(
                  dimension: _viewport,
                  child: Stack(
                    children: [
                      InteractiveViewer(
                        key: ValueKey(_turns),
                        transformationController: _transform,
                        constrained: false,
                        minScale: 1,
                        maxScale: 5,
                        boundaryMargin: EdgeInsets.zero,
                        child: SizedBox(
                          width: _image.width * _base,
                          height: _image.height * _base,
                          child: RawImage(image: _image, fit: BoxFit.fill),
                        ),
                      ),
                      // Moldura do quadrado que vai virar a capa.
                      IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: c.tx.withValues(alpha: 0.7),
                              width: 2,
                            ),
                            borderRadius: BorderRadius.circular(
                              BergaSizes.coverRadius,
                            ),
                          ),
                          child: const SizedBox.expand(),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(Icons.zoom_out, size: 20, color: c.mu),
                Expanded(
                  child: Slider(
                    value: zoom,
                    min: 1,
                    max: 5,
                    onChanged: _saving ? null : _setZoom,
                  ),
                ),
                Icon(Icons.zoom_in, size: 20, color: c.mu),
                IconButton(
                  tooltip: 'Girar',
                  onPressed: _saving ? null : _rotate,
                  icon: Icon(Icons.rotate_right, color: c.tx),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.end,
              children: [
                AppChip(
                  label: 'Cancelar',
                  onTap: _saving ? null : () => Navigator.pop(context),
                ),
                AppChip(
                  label: 'Usar inteira',
                  onTap: _saving ? null : () => _save(crop: false),
                ),
                AppChip(
                  label: 'Recortar',
                  active: true,
                  onTap: _saving ? null : () => _save(crop: true),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
