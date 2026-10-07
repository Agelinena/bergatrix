import 'dart:math';

import '../../data/models/search_result.dart';

/// Modo de repetição (Seção 7.2): desligado → tudo → uma faixa.
enum PlayerRepeat {
  desligado,
  tudo,
  umaFaixa;

  PlayerRepeat get next => values[(index + 1) % values.length];
}

/// Uma faixa na fila. [uid] diferencia a mesma música adicionada duas vezes.
class QueueItem {
  const QueueItem(this.uid, this.track);

  final int uid;
  final SearchResult track;

  @override
  String toString() => 'QueueItem($uid, ${track.title})';
}

/// Resultado de "anterior".
enum PreviousAction { reiniciar, voltar }

/// As duas filas do player (Seção 7), sem áudio nenhum.
///
/// - **Sua fila** ([manual]): "Adicionar à fila". A primeira adicionada toca
///   logo depois da atual (ordem de chegada). Nunca é embaralhada.
/// - **A seguir** ([upNext]): as faixas seguintes da lista que está tocando
///   (playlist, álbum, busca), na ordem ou embaralhadas.
class PlayQueue {
  PlayQueue({Random? random}) : _random = random ?? Random();

  final Random _random;
  int _nextUid = 0;

  QueueItem? _current;
  final List<QueueItem> _manual = [];
  final List<QueueItem> _upNext = [];

  /// Lista de origem completa (para desligar o aleatório e repetir tudo).
  List<QueueItem> _source = [];

  /// Faixas já tocadas nesta sessão (para "anterior").
  final List<QueueItem> _history = [];

  bool _shuffle = false;
  PlayerRepeat repeat = PlayerRepeat.desligado;

  QueueItem? get current => _current;
  List<QueueItem> get manual => List.unmodifiable(_manual);
  List<QueueItem> get upNext => List.unmodifiable(_upNext);
  bool get shuffle => _shuffle;

  QueueItem _item(SearchResult track) => QueueItem(_nextUid++, track);

  /// Toca [tracks] a partir de [index]. A sua fila é preservada (Seção 7.2).
  QueueItem playList(List<SearchResult> tracks, int index) {
    _source = [for (final t in tracks) _item(t)];
    if (_current != null) _history.add(_current!);
    _current = _source[index];
    _fillUpNextAfter(index);
    return _current!;
  }

  void _fillUpNextAfter(int index) {
    _upNext
      ..clear()
      ..addAll(
        _shuffle
            ? ([..._source]..removeAt(index)).toList()
            : _source.sublist(index + 1),
      );
    if (_shuffle) _upNext.shuffle(_random);
  }

  /// "Adicionar à fila": entra no fim da sua fila (FIFO).
  QueueItem add(SearchResult track) {
    final item = _item(track);
    _manual.add(item);
    return item;
  }

  /// Próxima faixa, ou nula para parar. [ended] = a faixa acabou sozinha
  /// (com "repetir uma faixa" ela recomeça; o botão Próxima avança).
  QueueItem? next({bool ended = false}) {
    if (_current == null) return null;
    if (ended && repeat == PlayerRepeat.umaFaixa) return _current;

    QueueItem? candidate;
    if (_manual.isNotEmpty) {
      candidate = _manual.removeAt(0);
    } else if (_upNext.isNotEmpty) {
      candidate = _upNext.removeAt(0);
    } else if (repeat == PlayerRepeat.tudo && _source.isNotEmpty) {
      _upNext.addAll(_source);
      if (_shuffle) _upNext.shuffle(_random);
      candidate = _upNext.removeAt(0);
    }
    if (candidate == null) return null;
    _history.add(_current!);
    _current = candidate;
    return candidate;
  }

  /// "Anterior": com mais de 3 s tocados, recomeça a faixa; senão volta à
  /// anterior do histórico (a atual volta para o início de "a seguir").
  PreviousAction previous(Duration position) {
    if (position > const Duration(seconds: 3) || _history.isEmpty) {
      return PreviousAction.reiniciar;
    }
    _upNext.insert(0, _current!);
    _current = _history.removeLast();
    return PreviousAction.voltar;
  }

  /// Liga/desliga o aleatório. Só "a seguir" muda; a sua fila não.
  void setShuffle(bool value) {
    if (value == _shuffle) return;
    _shuffle = value;
    if (_current == null) return;
    if (value) {
      _upNext.shuffle(_random);
    } else {
      // Volta à ordem da lista, a partir da faixa atual.
      final index = _source.indexWhere((i) => i.uid == _current!.uid);
      if (index >= 0) _fillUpNextAfter(index);
    }
  }

  void removeManual(int uid) => _manual.removeWhere((i) => i.uid == uid);

  void removeUpNext(int uid) => _upNext.removeWhere((i) => i.uid == uid);

  void clearManual() => _manual.clear();

  void reorderManual(int oldIndex, int newIndex) =>
      _reorder(_manual, oldIndex, newIndex);

  void reorderUpNext(int oldIndex, int newIndex) =>
      _reorder(_upNext, oldIndex, newIndex);

  /// [newIndex] é a posição final do item (padrão do `onReorderItem`).
  static void _reorder(List<QueueItem> list, int oldIndex, int newIndex) {
    list.insert(newIndex, list.removeAt(oldIndex));
  }

  /// Começa a tocar um item da sua fila quando nada estava carregado.
  QueueItem? startFromManual() {
    if (_current != null || _manual.isEmpty) return null;
    _current = _manual.removeAt(0);
    return _current;
  }
}
