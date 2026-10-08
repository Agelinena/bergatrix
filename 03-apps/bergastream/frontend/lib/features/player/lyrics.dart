import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_error.dart';
import '../../core/theme/berga_colors.dart';
import '../../core/theme/berga_sizes.dart';
import '../../core/theme/berga_text.dart';
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

/// Letra da faixa: do aparelho (já vista antes, funciona offline) ou do
/// servidor, que busca no LRCLIB.
final lyricsProvider = FutureProvider.autoDispose.family<Lyrics, LyricsRequest>(
  (ref, request) async {
    final db = ref.watch(localDatabaseProvider);
    final key = 'lyrics.${request.track.id}';
    final cached = await db?.stateValue(key);
    if (cached != null) {
      return Lyrics.fromJson(jsonDecode(cached) as Map<String, dynamic>);
    }
    if (!ref.read(sessionProvider).canUseServer) return Lyrics.none;
    try {
      final lyrics = await ref
          .read(lyricsRepositoryProvider)
          .lyrics(request.track);
      if (lyrics.found) await db?.setStateValue(key, jsonEncode(lyrics));
      return lyrics;
    } on ApiException {
      return Lyrics.none;
    }
  },
  retry: (_, _) => null,
);

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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lyrics = ref.watch(lyricsProvider(LyricsRequest(track))).value;
    if (lyrics == null || !lyrics.found) return const SizedBox.shrink();
    final c = BergaColors.of(context);
    final List<Widget> lines;
    if (lyrics.isSynced) {
      final position = ref.watch(playerPositionProvider).value ?? Duration.zero;
      final current = currentLineIndex(lyrics.synced, position);
      final start = current < 0 ? 0 : current;
      lines = [
        for (var i = start; i < lyrics.synced.length && i < start + 4; i++)
          Text(
            lyrics.synced[i].text.isEmpty ? '♪' : lyrics.synced[i].text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: BergaText.h2.copyWith(
              color: i == current ? c.tx : c.mu,
              fontWeight: i == current ? FontWeight.w800 : FontWeight.w600,
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
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: c.card,
            borderRadius: BorderRadius.circular(BergaSizes.cardRadius),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 6,
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
  final c = BergaColors.of(context);
  return Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => Scaffold(
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
      ),
    ),
  );
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
    final lyrics = async.value;
    if (lyrics == null) {
      return Padding(
        padding: padding,
        child: Text(async.isLoading ? 'Carregando letra…' : '', style: mu),
      );
    }
    if (!lyrics.found) {
      return Padding(
        padding: padding,
        child: Text('Letra indisponível para esta música.', style: mu),
      );
    }
    if (!lyrics.isSynced) {
      return SingleChildScrollView(
        padding: padding,
        child: Text(
          lyrics.plain ?? '',
          style: BergaText.body.copyWith(color: c.tx, height: 1.5),
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
