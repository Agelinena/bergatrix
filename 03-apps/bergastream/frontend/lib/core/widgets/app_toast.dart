import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/berga_colors.dart';
import '../theme/berga_sizes.dart';
import '../theme/berga_text.dart';

/// Aviso rápido: pílula verde no topo, visível por 1,5 s, com fade.
/// Um aviso novo substitui o anterior.
abstract final class AppToast {
  static OverlayEntry? _current;

  static void show(BuildContext context, String message) {
    final colors = BergaColors.of(context);
    // Aceita também o contexto do próprio Overlay (usado por quem fica acima
    // do Navigator, como a oferta de enviar playlists locais).
    final overlay = context is StatefulElement && context.state is OverlayState
        ? context.state as OverlayState
        : Overlay.of(context, rootOverlay: true);

    _current?.remove();
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _ToastView(
        message: message,
        colors: colors,
        onDone: () {
          if (_current == entry) _current = null;
          entry.remove();
        },
      ),
    );
    _current = entry;
    overlay.insert(entry);
  }
}

class _ToastView extends StatefulWidget {
  const _ToastView({
    required this.message,
    required this.colors,
    required this.onDone,
  });

  final String message;
  final BergaColors colors;
  final VoidCallback onDone;

  @override
  State<_ToastView> createState() => _ToastViewState();
}

class _ToastViewState extends State<_ToastView>
    with SingleTickerProviderStateMixin {
  late final _fade = AnimationController(
    vsync: this,
    duration: BergaSizes.toastFade,
  )..forward();
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(BergaSizes.toastDuration, () async {
      await _fade.reverse();
      widget.onDone();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    return Positioned(
      top: MediaQuery.paddingOf(context).top + BergaSizes.toastTop,
      left: 16,
      right: 16,
      child: IgnorePointer(
        child: FadeTransition(
          opacity: _fade,
          child: Material(
            type: MaterialType.transparency,
            child: Center(
              child: Container(
                padding: BergaSizes.toastPadding,
                decoration: ShapeDecoration(
                  color: c.gr,
                  shape: const StadiumBorder(),
                ),
                child: Text(
                  widget.message,
                  textAlign: TextAlign.center,
                  style: BergaText.toast.copyWith(color: c.on),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
