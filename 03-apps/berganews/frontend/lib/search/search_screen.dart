import 'package:flutter/material.dart';

import '../articles/article_list.dart';
import '../core/widgets.dart';
import '../data/api.dart';

Future<void> openSearch(BuildContext context) => Navigator.of(
  context,
).push(MaterialPageRoute<void>(builder: (_) => const SearchScreen()));

/// Busca em texto completo (manchete, trecho e matéria), em português e
/// inglês, sem ligar para acento. Aceita "aspas" e -palavra.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _field = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _field,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            hintText: 'Buscar nas matérias',
            border: InputBorder.none,
          ),
          onSubmitted: (v) => setState(() => _query = v.trim()),
        ),
        actions: [
          if (_query.isNotEmpty)
            IconButton(
              tooltip: 'Limpar',
              onPressed: () {
                _field.clear();
                setState(() => _query = '');
              },
              icon: const Icon(Icons.close),
            ),
        ],
      ),
      body: _query.isEmpty
          ? const MessageView(
              icon: Icons.search,
              title: 'Busque por palavras',
              message: 'Use "aspas" para a frase exata e -palavra para excluir.',
            )
          : ArticleList(
              query: ArticleQuery(q: _query),
              emptyTitle: 'Nada encontrado',
              emptyMessage: 'Tente outras palavras.',
            ),
    );
  }
}
