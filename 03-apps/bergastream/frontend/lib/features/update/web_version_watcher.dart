import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/app_platform.dart';
import '../../core/theme/berga_colors.dart';
import '../../core/theme/berga_sizes.dart';
import '../../core/theme/berga_text.dart';
import '../../core/widgets/widgets.dart';
import 'page_reload.dart';

/// Versão publicada do app web (`version.json` do build), sem cache. Nulo
/// fora da web.
typedef WebVersionFetcher = Future<String?> Function();

final webVersionFetcherProvider = Provider<WebVersionFetcher?>((ref) {
  final platform = ref.watch(appPlatformProvider);
  if (!platform.isWeb) return null;
  final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 10)));
  return () async {
    try {
      final response = await dio.get<Map<String, dynamic>>(
        Uri.base.resolve('/version.json').toString(),
        queryParameters: {'t': DateTime.now().millisecondsSinceEpoch},
      );
      final data = response.data;
      if (data == null) return null;
      return '${data['version']}+${data['build_number']}';
    } on Object {
      return null;
    }
  };
});

/// Web: aba aberta há tempo continua com o app antigo depois de uma
/// atualização do servidor. Confere a versão publicada de tempos em tempos
/// e ao voltar para a aba; se mudou, oferece "Recarregar".
class WebVersionWatcher extends ConsumerStatefulWidget {
  const WebVersionWatcher({super.key, required this.child});

  final Widget child;

  static const interval = Duration(minutes: 15);

  @override
  ConsumerState<WebVersionWatcher> createState() => _WebVersionWatcherState();
}

class _WebVersionWatcherState extends ConsumerState<WebVersionWatcher> {
  String? _running;
  bool _outdated = false;
  Timer? _timer;
  AppLifecycleListener? _lifecycle;

  @override
  void initState() {
    super.initState();
    final fetch = ref.read(webVersionFetcherProvider);
    if (fetch == null) return;
    // A versão desta página é a publicada quando ela abriu.
    unawaited(fetch().then((v) => _running = v));
    _timer = Timer.periodic(WebVersionWatcher.interval, (_) => _check());
    _lifecycle = AppLifecycleListener(onResume: _check);
  }

  Future<void> _check() async {
    final fetch = ref.read(webVersionFetcherProvider);
    if (fetch == null || _outdated || _running == null) return;
    final published = await fetch();
    if (mounted && published != null && published != _running) {
      setState(() => _outdated = true);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _lifecycle?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_outdated) return widget.child;
    final c = BergaColors.of(context);
    return Stack(
      children: [
        widget.child,
        Positioned(
          left: 16,
          right: 16,
          top: 16,
          child: SafeArea(
            child: Center(
              child: Material(
                color: c.card,
                elevation: 6,
                borderRadius: BorderRadius.circular(BergaSizes.cardRadius),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    spacing: 12,
                    children: [
                      Flexible(
                        child: Text(
                          'Nova versão do Bergastream',
                          style: BergaText.body.copyWith(color: c.tx),
                        ),
                      ),
                      const AppChip(
                        label: 'Recarregar',
                        active: true,
                        onTap: reloadPage,
                      ),
                      IconButton(
                        tooltip: 'Depois',
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () => setState(() => _outdated = false),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
