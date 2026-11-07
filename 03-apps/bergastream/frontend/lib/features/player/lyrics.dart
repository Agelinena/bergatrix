import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_error.dart';
import '../../core/theme/berga_colors.dart';
import '../../core/theme/berga_sizes.dart';
import '../../core/theme/berga_text.dart';
import '../../core/widgets/widgets.dart';
import '../../data/local/database.dart';
import '../../data/models/search_result.dart';
import '../../data/repositories/lyrics_repository.dart';
import '../auth/session.dart';
import 'player_controller.dart';

/// Pedido de letra: igualdade pelo id da faixa (chave do provider).
class LyricsRequest {
  const LyricsRequest(this.track);

  final SearchResult track;

  @override
  bool operator ==(Object other) =>
      other is LyricsRequest && other.track.id == track.id;

  @override
  int get hashCode => track.id.hashCode;
}

/// Letra da faixa: do servidor (que busca no LRCLIB e guarda as correções
/// de todos) e, sem servidor, a cópia do aparelho (já vista antes).
final lyricsProvider = FutureProvider.autoDispose.family<Lyrics, LyricsRequest>(
  (ref, request) async {
    final db = ref.watch(localDatabaseProvider);
    final key = 'lyrics.${request.track.id}';
    Future<Lyrics> cached() async {
      final raw = await db?.stateValue(key);
      return raw == null
          ? Lyrics.none
          : Lyrics.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    }

    if (!ref.read(sessionProvider).canUseServer) return cached();
    try {
      final lyrics = await ref
          .read(lyricsRepositoryProvider)
          .lyrics(request.track);
      if (lyrics.found) await db?.setStateValue(key, jsonEncode(lyrics));
      return lyrics;
    } on ApiException {
      return cached();
    }
  },
  retry: (_, _) => null,
);

/// Ajuste de sincronia ainda não salvo (ms), por faixa: a letra na tela já
/// anda junto enquanto a pessoa acerta.
final lyricsShiftProvider = NotifierProvider.family<LyricsShift, int, String>(
  LyricsShift.new,
);

class LyricsShift extends Notifier<int> {
  LyricsShift(this.trackId);

  final String trackId;

  @override
  int build() => 0;

  void add(int ms) => state += ms;
  void clear() => state = 0;
}

/// Letra com o ajuste em andamento aplicado.
Lyrics? shiftedLyrics(WidgetRef ref, SearchResult track) {
  final lyrics = ref.watch(lyricsProvider(LyricsRequest(track))).value;
  if (lyrics == null) return null;
  return lyrics.shifted(ref.watch(lyricsShiftProvider(track.id)));
}

/// Linha que está tocando: a última que já começou (−1 antes da primeira).
int currentLineIndex(List<LyricLine> lines, Duration position) {
  // Um pouco adiantado: a linha acende junto com a voz, não depois.
  final at = position + const Duration(milliseconds: 250);
  var index = -1;
  for (final (i, line) in lines.indexed) {
    if (line.time <= at) {
      index = i;
    } else {
      break;
    }
  }
  return index;
}

/// Cartão "Letra" no player grande (como no Spotify): a linha atual e as
/// próximas. Tocar abre a letra inteira. Some se a música não tem letra.
class LyricsCard extends ConsumerWidget {
  const LyricsCard({super.key, required this.track});

  final SearchResult track;

  static const title = 'Letra';

  /// Linhas no cartão (a anterior, a atual e as próximas).
  static const visibleLines = 7;

  /// Altura mínima: o cartão não "pula" quando as linhas mudam.
  static const minHeight = 360.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lyrics = shiftedLyrics(ref, track);
    if (lyrics == null || !lyrics.found) return const SizedBox.shrink();
    final c = BergaColors.of(context);
    final List<Widget> lines;
    if (lyrics.isSynced) {
      final position = ref.watch(playerPositionProvider).value ?? Duration.zero;
      final current = currentLineIndex(lyrics.synced, position);
      // A anterior (apagada), a atual e as próximas: letra grande, como no
      // Spotify.
      final start = current < 1 ? 0 : current - 1;
      lines = [
        for (
          var i = start;
          i < lyrics.synced.length && i < start + visibleLines;
          i++
        )
          Text(
            lyrics.synced[i].text.isEmpty ? '♪' : lyrics.synced[i].text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: BergaText.h2.copyWith(
              fontSize: 22,
              height: 1.3,
              color: i == current
                  ? c.tx
                  : i < current
                  ? c.mu.withValues(alpha: 0.6)
                  : c.mu,
              fontWeight: FontWeight.w800,
            ),
          ),
      ];
    } else {
      lines = [
        Text(
          lyrics.plain ?? '',
          maxLines: 5,
          overflow: TextOverflow.ellipsis,
          style: BergaText.body.copyWith(color: c.tx),
        ),
      ];
    }
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: GestureDetector(
        onTap: () => openLyrics(context, track),
        child: Container(
          width: double.infinity,
          constraints: BoxConstraints(
            minHeight: lyrics.isSynced ? minHeight : 0,
          ),
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: c.card,
            borderRadius: BorderRadius.circular(BergaSizes.cardRadius),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 10,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: BergaText.trackTitle.copyWith(color: c.tx),
                    ),
                  ),
                  Icon(Icons.open_in_full, size: 18, color: c.mu),
                ],
              ),
              ...lines,
            ],
          ),
        ),
      ),
    );
  }
}

/// Letra inteira em tela cheia.
Future<void> openLyrics(BuildContext context, SearchResult track) {
  return Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => LyricsPage(track: track),
    ),
  );
}

/// Letra em tela cheia. A música mudou (acabou ou trocaram): fecha e volta
/// ao player — a letra era de outra música.
class LyricsPage extends ConsumerWidget {
  const LyricsPage({super.key, required this.track});

  final SearchResult track;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = BergaColors.of(context);
    ref.listen(playerProvider.select((s) => s.current?.track.id), (_, id) {
      if (id != track.id && (ModalRoute.of(context)?.isCurrent ?? false)) {
        Navigator.of(context).pop();
      }
    });
    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppBar(
        backgroundColor: c.bg,
        foregroundColor: c.tx,
        elevation: 0,
        title: Text(
          track.title,
          style: BergaText.trackTitle.copyWith(color: c.tx),
        ),
      ),
      body: LyricsView(track: track),
    );
  }
}

/// Letra inteira, rolando sozinha com a música (tela cheia e painel do
/// navegador). Tocar numa linha pula para ela. Rolar com o dedo pausa a
/// rolagem automática por alguns segundos.
class LyricsView extends ConsumerStatefulWidget {
  const LyricsView({super.key, required this.track, this.padding});

  final SearchResult track;
  final EdgeInsets? padding;

  static const manualScrollPause = Duration(seconds: 4);

  @override
  ConsumerState<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends ConsumerState<LyricsView> {
  final _keys = <int, GlobalKey>{};
  int _shown = -2;
  DateTime _userScrolledAt = DateTime.fromMillisecondsSinceEpoch(0);

  GlobalKey _keyFor(int i) => _keys.putIfAbsent(i, GlobalKey.new);

  void _follow(int index) {
    if (index == _shown) return;
    _shown = index;
    if (DateTime.now().difference(_userScrolledAt) <
        LyricsView.manualScrollPause) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = _keys[index < 0 ? 0 : index]?.currentContext;
      if (context == null || !context.mounted) return;
      Scrollable.ensureVisible(
        context,
        alignment: 0.35,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = BergaColors.of(context);
    final mu = BergaText.secondary.copyWith(color: c.mu);
    final async = ref.watch(lyricsProvider(LyricsRequest(widget.track)));
    final padding =
        widget.padding ?? const EdgeInsets.fromLTRB(20, 12, 20, 120);
    final lyrics = shiftedLyrics(ref, widget.track);
    final online = ref.watch(sessionProvider.select((s) => s.canUseServer));
    if (lyrics == null) {
      return Padding(
        padding: padding,
        child: Text(async.isLoading ? 'Carregando letra…' : '', style: mu),
      );
    }
    final tools = online && lyrics.trackId != null
        ? Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => showLyricsEditor(context, ref, widget.track),
              icon: Icon(
                lyrics.found ? Icons.tune : Icons.edit_note,
                size: 18,
                color: c.gr,
              ),
              label: Text(
                lyrics.found ? 'Ajustar letra' : 'Escrever a letra',
                style: BergaText.secondary.copyWith(color: c.gr),
              ),
            ),
          )
        : null;
    if (!lyrics.found) {
      return Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Letra indisponível para esta música.', style: mu),
            ?tools,
          ],
        ),
      );
    }
    if (!lyrics.isSynced) {
      return SingleChildScrollView(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ?tools,
            Text(
              lyrics.plain ?? '',
              style: BergaText.body.copyWith(color: c.tx, height: 1.5),
            ),
          ],
        ),
      );
    }
    final position = ref.watch(playerPositionProvider).value ?? Duration.zero;
    final current = currentLineIndex(lyrics.synced, position);
    _follow(current);
    final controller = ref.read(playerProvider.notifier);
    return NotificationListener<UserScrollNotification>(
      onNotification: (_) {
        _userScrolledAt = DateTime.now();
        return false;
      },
      child: SingleChildScrollView(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ?tools,
            for (final (i, line) in lyrics.synced.indexed)
              GestureDetector(
                key: _keyFor(i),
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  _userScrolledAt = DateTime.fromMillisecondsSinceEpoch(0);
                  controller.seek(line.time);
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    line.text.isEmpty ? '♪' : line.text,
                    style: BergaText.h2.copyWith(
                      fontSize: 22,
                      height: 1.25,
                      fontWeight: FontWeight.w800,
                      color: i == current
                          ? c.tx
                          : i < current
                          ? c.mu.withValues(alpha: 0.6)
                          : c.mu,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// "Ajustar letra": sincronia (a letra anda na tela enquanto ajusta), texto
/// e "buscar de novo". Vale para todos que ouvem a música.
Future<void> showLyricsEditor(
  BuildContext context,
  WidgetRef ref,
  SearchResult track,
) async {
  final lyrics = ref.read(lyricsProvider(LyricsRequest(track))).value;
  final trackId = lyrics?.trackId;
  if (lyrics == null || trackId == null) return;
  if (!lyrics.found) {
    await _editText(context, ref, track, lyrics);
    return;
  }
  final c = BergaColors.of(context);
  final shift = ref.read(lyricsShiftProvider(track.id).notifier);
  final choice = await showModalBottomSheet<String>(
    context: context,
    useRootNavigator: true,
    backgroundColor: c.card,
    barrierColor: Colors.transparent,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(BergaSizes.sheetRadius),
      ),
    ),
    builder: (sheet) => _LyricsEditorSheet(track: track),
  );
  // Fechou sem salvar: a prévia sai.
  shift.clear();
  if (choice == 'texto' && context.mounted) {
    await _editText(context, ref, track, lyrics);
  }
}

/// Atraso/adiantamento em texto ("+1,25 s", "−1 s").
String offsetLabel(int ms) {
  if (ms == 0) return 'sem ajuste';
  return '${ms > 0 ? '+' : '−'}${_seconds(ms.abs())} s';
}

String _seconds(int ms) {
  var text = (ms / 1000).toStringAsFixed(2);
  while (text.endsWith('0')) {
    text = text.substring(0, text.length - 1);
  }
  if (text.endsWith('.')) text = text.substring(0, text.length - 1);
  return text.replaceAll('.', ',');
}

class _LyricsEditorSheet extends ConsumerWidget {
  const _LyricsEditorSheet({required this.track});

  final SearchResult track;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = BergaColors.of(context);
    final mu = BergaText.secondary.copyWith(color: c.mu);
    final base = ref.watch(lyricsProvider(LyricsRequest(track))).value;
    final delta = ref.watch(lyricsShiftProvider(track.id));
    final shift = ref.read(lyricsShiftProvider(track.id).notifier);
    if (base == null || base.trackId == null) return const SizedBox.shrink();
    final total = base.offsetMs + delta;

    Future<void> save(Future<Lyrics> Function() action, String done) async {
      try {
        await action();
        shift.clear();
        ref.invalidate(lyricsProvider(LyricsRequest(track)));
        if (context.mounted) {
          AppToast.show(context, done);
          Navigator.of(context).pop();
        }
      } on ApiException catch (e) {
        if (context.mounted) AppToast.show(context, e.serverMessage);
      }
    }

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 10,
          children: [
            Text(
              'Ajustar letra',
              style: BergaText.trackTitle.copyWith(color: c.tx),
            ),
            if (base.isSynced) ...[
              Text('Sincronia: ${offsetLabel(total)}', style: mu),
              Text(
                'A letra aparece antes da voz? Toque em "+" (atrasa). Depois '
                'da voz? Toque em "−" (adianta). A letra na tela já muda.',
                style: mu,
              ),
              Wrap(
                spacing: BergaSizes.chipGap,
                runSpacing: 8,
                children: [
                  for (final step in const [-1000, -250, 250, 1000])
                    AppChip(
                      label: offsetLabel(step),
                      onTap: () => shift.add(step),
                    ),
                  if (total != 0)
                    AppChip(label: 'Zerar', onTap: () => shift.add(-total)),
                ],
              ),
            ],
            Wrap(
              spacing: BergaSizes.chipGap,
              runSpacing: 8,
              children: [
                if (delta != 0)
                  AppChip(
                    label: 'Salvar para todos',
                    active: true,
                    onTap: () => save(
                      () => ref
                          .read(lyricsRepositoryProvider)
                          .edit(base.trackId!, offsetMs: total),
                      'Sincronia salva',
                    ),
                  ),
                AppChip(
                  label: 'Editar o texto',
                  icon: Icons.edit_note,
                  // O editor abre depois que esta folha fecha.
                  onTap: () => Navigator.of(context).pop('texto'),
                ),
                if (base.edited)
                  AppChip(
                    label: 'Buscar de novo',
                    icon: Icons.restart_alt,
                    onTap: () => save(
                      () => ref
                          .read(lyricsRepositoryProvider)
                          .reset(base.trackId!),
                      'Letra original de volta',
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _editText(
  BuildContext context,
  WidgetRef ref,
  SearchResult track,
  Lyrics lyrics,
) async {
  final synced = lyrics.lrc != null && lyrics.lrc!.trim().isNotEmpty;
  final result = await showFormDialog(
    context,
    title: lyrics.found ? 'Editar a letra' : 'Escrever a letra',
    confirmLabel: 'Salvar para todos',
    note: synced
        ? 'Cada linha começa com o tempo em que é cantada: "[01:02.50] '
              'texto". Para mudar só o atraso de tudo, use "Ajustar letra".'
        : 'Uma linha por verso. Para a letra acompanhar a música, comece '
              'cada linha com o tempo: "[01:02.50] texto".',
    fields: [
      FormFieldSpec(
        'Letra',
        initial: synced ? lyrics.lrc! : (lyrics.plain ?? ''),
        maxLines: 12,
        maxLength: 60000,
      ),
    ],
  );
  if (result == null || !context.mounted) return;
  final text = result.values.single;
  // Com tempos vira a sincronizada; sem, o texto simples.
  final timed = RegExp(r'^\s*\[\d+:\d{1,2}').hasMatch(text);
  try {
    await ref
        .read(lyricsRepositoryProvider)
        .edit(
          lyrics.trackId!,
          lrc: timed ? text : (synced ? '' : null),
          plain: timed ? null : text,
        );
    ref.invalidate(lyricsProvider(LyricsRequest(track)));
    if (context.mounted) AppToast.show(context, 'Letra salva');
  } on ApiException catch (e) {
    if (context.mounted) AppToast.show(context, e.serverMessage);
  }
}
