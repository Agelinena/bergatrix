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

  /// Faixas da lista que já tocaram desde "tocar esta lista" (a sessão):
  /// religar o aleatório sorteia só as que ainda não tocaram.
  final Set<int> _played = {};

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
    _played
      ..clear()
      ..add(_current!.uid);
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

  /// A que vem depois da atual, sem avançar (para baixar antes).
  QueueItem? get peekNext {
    if (_current == null || repeat == PlayerRepeat.umaFaixa) return null;
    if (_manual.isNotEmpty) return _manual.first;
    if (_upNext.isNotEmpty) return _upNext.first;
    return null;
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
      // Recomeça a lista: nova volta, tudo pode tocar de novo.
      _played.clear();
      _upNext.addAll(_source);
      if (_shuffle) _upNext.shuffle(_random);
      candidate = _upNext.removeAt(0);
    }
    if (candidate == null) return null;
    _history.add(_current!);
    _current = candidate;
    _played.add(candidate.uid);
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
  /// Ligar sorteia todas as faixas da lista que ainda não tocaram nesta
  /// sessão (não só as que estavam depois da atual); desligar segue a ordem
  /// da lista a partir da atual.
  void setShuffle(bool value) {
    if (value == _shuffle) return;
    _shuffle = value;
    if (_current == null) return;
    if (value) {
      _upNext
        ..clear()
        ..addAll([
          for (final i in _source)
            if (i.uid != _current!.uid && !_played.contains(i.uid)) i,
        ])
        ..shuffle(_random);
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

  // ── Guardar e restaurar (o player volta igual ao reabrir o app) ──

  Map<String, dynamic> toJson() {
    Map<String, dynamic> refOf(QueueItem item) {
      final index = _source.indexWhere((s) => s.uid == item.uid);
      return index >= 0 ? {'i': index} : {'t': item.track.toJson()};
    }

    final history = _history.length > 50
        ? _history.sublist(_history.length - 50)
        : _history;
    return {
      'source': [for (final s in _source) s.track.toJson()],
      'current': _current == null ? null : refOf(_current!),
      'manual': [for (final m in _manual) m.track.toJson()],
      'up_next': [for (final u in _upNext) refOf(u)],
      'history': [for (final h in history) refOf(h)],
      'played': [
        for (final (i, s) in _source.indexed)
          if (_played.contains(s.uid)) i,
      ],
      'shuffle': _shuffle,
      'repeat': repeat.name,
    };
  }

  /// Restaura o que [toJson] guardou. Ignora dados inválidos.
  void restore(Map<String, dynamic> json) {
    SearchResult track(Object? t) =>
        SearchResult.fromJson(t! as Map<String, dynamic>);
    final source = [
      for (final t in json['source'] as List<dynamic>) _item(track(t)),
    ];
    QueueItem? resolve(Object? ref) {
      if (ref is! Map<String, dynamic>) return null;
      final index = ref['i'];
      if (index is int) {
        return index >= 0 && index < source.length ? source[index] : null;
      }
      return ref['t'] == null ? null : _item(track(ref['t']));
    }

    _source = source;
    _current = resolve(json['current']);
    _manual
      ..clear()
      ..addAll([
        for (final t in json['manual'] as List<dynamic>) _item(track(t)),
      ]);
    _upNext
      ..clear()
      ..addAll([for (final r in json['up_next'] as List<dynamic>) ?resolve(r)]);
    _history
      ..clear()
      ..addAll([for (final r in json['history'] as List<dynamic>) ?resolve(r)]);
    _played
      ..clear()
      ..addAll([
        for (final i in json['played'] as List<dynamic>)
          if (i is int && i >= 0 && i < source.length) source[i].uid,
      ]);
    _shuffle = json['shuffle'] as bool? ?? false;
    repeat = PlayerRepeat.values.firstWhere(
      (r) => r.name == json['repeat'],
      orElse: () => PlayerRepeat.desligado,
    );
  }

  /// Fila de uma sessão compartilhada: a lista inteira, com a atual em
  /// [index] (as anteriores viram o histórico) e as [manual] seguintes como
  /// "sua fila". Sem aleatório nem repetição: a ordem é a mesma para todos.
  /// Devolve os itens na ordem de [tracks].
  List<QueueItem> loadShared(
    List<SearchResult> tracks,
    int index, {
    int manual = 0,
  }) {
    final items = [for (final t in tracks) _item(t)];
    final valid = index >= 0 && index < items.length;
    _source = items;
    _manual.clear();
    _played.clear();
    _shuffle = false;
    repeat = PlayerRepeat.desligado;
    _history
      ..clear()
      ..addAll(valid ? items.sublist(0, index) : const []);
    _current = valid ? items[index] : null;
    final split = valid
        ? (index + 1 + manual).clamp(index + 1, items.length)
        : 0;
    _manual.addAll(valid ? items.sublist(index + 1, split) : const []);
    _upNext
      ..clear()
      ..addAll(valid ? items.sublist(split) : const []);
    return items;
  }

  /// Começa a tocar um item da sua fila quando nada estava carregado.
  QueueItem? startFromManual() {
    if (_current != null || _manual.isEmpty) return null;
    _current = _manual.removeAt(0);
    return _current;
  }
}
