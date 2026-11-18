import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_error.dart';
import '../../core/theme/berga_colors.dart';
import '../../core/theme/berga_sizes.dart';
import '../../core/theme/berga_text.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/search_result.dart';
import '../../data/repositories/lyrics_repository.dart';
import 'player_controller.dart';

/// Uma linha na marcação: o texto e o tempo marcado (nulo = falta marcar).
class MarkLine {
  MarkLine(this.text, [this.time]);

  final String text;
  Duration? time;
}

/// Linhas para marcar: as da letra sincronizada (com os tempos de agora, que
/// dá para remarcar) ou as da letra simples (sem tempo).
List<MarkLine> markLinesFrom(Lyrics lyrics) {
  if (lyrics.isSynced) {
    return [
      for (final l in lyrics.synced)
        if (l.text.trim().isNotEmpty) MarkLine(l.text, l.time),
    ];
  }
  return [
    for (final l in (lyrics.plain ?? '').split('\n'))
      if (l.trim().isNotEmpty) MarkLine(l.trim()),
  ];
}

/// "[01:02.50]" de um tempo.
String lrcTime(Duration t) {
  final cs = (t.inMilliseconds / 10).round();
  final m = cs ~/ 6000;
  final s = (cs % 6000) / 100;
  return '[${m.toString().padLeft(2, '0')}:${s.toStringAsFixed(2).padLeft(5, '0')}]';
}

/// LRC das linhas marcadas, em ordem de tempo.
String toLrc(List<MarkLine> lines) {
  final timed = [
    for (final l in lines)
      if (l.time != null) l,
  ]..sort((a, b) => a.time!.compareTo(b.time!));
  return timed.map((l) => '${lrcTime(l.time!)} ${l.text}').join('\n');
}

/// Abre a marcação linha a linha da letra de [track] (tela cheia).
Future<bool?> openLyricsMarker(
  BuildContext context,
  SearchResult track,
  Lyrics lyrics,
) => Navigator.of(context, rootNavigator: true).push<bool>(
  MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => LyricsMarker(track: track, lyrics: lyrics),
  ),
);

/// Marcar a letra: com a música tocando, toca-se em "Marcar" (ou espaço)
/// quando cada linha começa a ser cantada. Tocar numa linha volta a música
/// para um pouco antes dela, para remarcar; ±0,1 s ajusta a linha escolhida.
class LyricsMarker extends ConsumerStatefulWidget {
  const LyricsMarker({super.key, required this.track, required this.lyrics});

  final SearchResult track;
  final Lyrics lyrics;

  /// Tempo de reação: quem marca aperta um pouco depois de a linha começar.
  static const reaction = Duration(milliseconds: 150);

  /// Ao escolher uma linha, a música volta isto antes dela.
  static const lead = Duration(seconds: 3);

  @override
  ConsumerState<LyricsMarker> createState() => _LyricsMarkerState();
}

class _LyricsMarkerState extends ConsumerState<LyricsMarker> {
  late final List<MarkLine> _lines = markLinesFrom(widget.lyrics);
  late int _selected = _firstUnmarked();
  final _keys = <int, GlobalKey>{};
  bool _saving = false;
  bool _changed = false;

  int _firstUnmarked() {
    final i = _lines.indexWhere((l) => l.time == null);
    return i < 0 ? 0 : i;
  }

  Duration get _position =>
      ref.read(playerPositionProvider).value ?? Duration.zero;

  PlayerController get _player => ref.read(playerProvider.notifier);

  void _show(int i) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _keys[i]?.currentContext;
      if (ctx != null && ctx.mounted) {
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.4,
          duration: const Duration(milliseconds: 200),
        );
      }
    });
  }

  void _mark() {
    if (_lines.isEmpty) return;
    final at = _position - LyricsMarker.reaction;
    setState(() {
      _lines[_selected].time = at.isNegative ? Duration.zero : at;
      _changed = true;
      if (_selected < _lines.length - 1) _selected++;
    });
    _show(_selected);
  }

  void _select(int i) {
    setState(() => _selected = i);
    final t = _lines[i].time;
    if (t != null) {
      final back = t - LyricsMarker.lead;
      _player.seek(back.isNegative ? Duration.zero : back);
    }
  }

  void _nudge(int ms) {
    final t = _lines[_selected].time;
    if (t == null) return;
    final moved = t + Duration(milliseconds: ms);
    setState(() {
      _lines[_selected].time = moved.isNegative ? Duration.zero : moved;
      _changed = true;
    });
  }

  void _move(int delta) {
    final i = (_selected + delta).clamp(0, _lines.length - 1);
    setState(() => _selected = i);
    _show(i);
  }

  int get _missing => _lines.where((l) => l.time == null).length;

  Future<void> _save() async {
    final trackId = widget.lyrics.trackId;
    if (trackId == null || _missing > 0) return;
    setState(() => _saving = true);
    try {
      await ref
          .read(lyricsRepositoryProvider)
          .edit(trackId, lrc: toLrc(_lines), offsetMs: 0);
      if (mounted) {
        AppToast.show(context, 'Letra sincronizada para todos');
        Navigator.of(context).pop(true);
      }
    } on ApiException catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        AppToast.show(context, e.serverMessage);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = BergaColors.of(context);
    final mu = BergaText.secondary.copyWith(color: c.mu);
    final position = ref.watch(playerPositionProvider).value ?? Duration.zero;
    final playing = ref.watch(playerProvider.select((s) => s.isPlaying));
    // Linha que está sendo cantada agora, pelos tempos marcados.
    var singing = -1;
    for (var i = 0; i < _lines.length; i++) {
      final t = _lines[i].time;
      if (t != null && t <= position) singing = i;
    }
    final selectedTime = _lines.isEmpty ? null : _lines[_selected].time;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.space): _mark,
        const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(-1),
        const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(1),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _nudge(-100),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _nudge(100),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Marcar a letra'),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Center(
                  child: AppChip(
                    label: _missing > 0
                        ? 'Faltam $_missing'
                        : 'Salvar para todos',
                    active: _missing == 0 && _changed,
                    onTap: _missing == 0 && _changed && !_saving ? _save : null,
                  ),
                ),
              ),
            ],
          ),
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                child: Text(
                  'Com a música tocando, toque em "Marcar" (ou aperte espaço) '
                  'quando cada linha começar a ser cantada. Tocar numa linha '
                  'volta um pouco antes dela para marcar de novo.',
                  style: mu,
                ),
              ),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                  itemCount: _lines.length,
                  itemBuilder: (context, i) {
                    final line = _lines[i];
                    final selected = i == _selected;
                    return InkWell(
                      key: _keys.putIfAbsent(i, GlobalKey.new),
                      borderRadius: BorderRadius.circular(
                        BergaSizes.coverRadius,
                      ),
                      onTap: () => _select(i),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          vertical: 8,
                          horizontal: 8,
                        ),
                        decoration: BoxDecoration(
                          color: selected ? c.card : null,
                          borderRadius: BorderRadius.circular(
                            BergaSizes.coverRadius,
                          ),
                        ),
                        child: Row(
                          spacing: 12,
                          children: [
                            SizedBox(
                              width: 74,
                              child: Text(
                                line.time == null
                                    ? '—'
                                    : lrcTime(
                                        line.time!,
                                      ).replaceAll(RegExp(r'[\[\]]'), ''),
                                style: mu.copyWith(
                                  color: line.time == null ? c.ac : c.mu,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                line.text,
                                style: BergaText.body.copyWith(
                                  color: i == singing
                                      ? c.gr
                                      : selected
                                      ? c.tx
                                      : c.mu,
                                  fontWeight: selected || i == singing
                                      ? FontWeight.w700
                                      : FontWeight.w400,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: Column(
                    spacing: 10,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        spacing: 8,
                        children: [
                          IconButton(
                            tooltip: 'Voltar 5 s',
                            onPressed: () {
                              final back =
                                  position - const Duration(seconds: 5);
                              _player.seek(
                                back.isNegative ? Duration.zero : back,
                              );
                            },
                            icon: Icon(Icons.replay_5, color: c.tx),
                          ),
                          IconButton(
                            tooltip: playing ? 'Pausar' : 'Tocar',
                            onPressed: _player.togglePlay,
                            icon: Icon(
                              playing ? Icons.pause : Icons.play_arrow,
                              color: c.tx,
                            ),
                          ),
                          AppChip(
                            label: '−0,1 s',
                            onTap: selectedTime == null
                                ? null
                                : () => _nudge(-100),
                          ),
                          AppChip(
                            label: '+0,1 s',
                            onTap: selectedTime == null
                                ? null
                                : () => _nudge(100),
                          ),
                        ],
                      ),
                      PrimaryButton(
                        label: 'Marcar',
                        icon: Icons.touch_app,
                        expanded: true,
                        onPressed: _lines.isEmpty ? null : _mark,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
