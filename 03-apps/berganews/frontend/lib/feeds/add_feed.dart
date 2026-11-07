import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/http.dart';
import '../core/widgets.dart';
import '../data/api.dart';
import '../data/models.dart';
import 'feeds_tabs.dart';
import 'manage.dart';

/// "Adicionar veículo": o endereço do site ou do feed (o servidor acha o
/// feed), o nome que a pessoa quiser e a pasta (ou uma pasta nova).
Future<void> showAddFeed(BuildContext context) => showDialog<void>(
  context: context,
  builder: (_) => const _AddFeedDialog(),
);

class _AddFeedDialog extends ConsumerStatefulWidget {
  const _AddFeedDialog();

  @override
  ConsumerState<_AddFeedDialog> createState() => _AddFeedDialogState();
}

class _AddFeedDialogState extends ConsumerState<_AddFeedDialog> {
  final _url = TextEditingController();
  final _name = TextEditingController();
  int? _folder;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _chooseFolder() async {
    final chosen = await pickFolder(context, ref, current: _folder, title: 'Pasta do veículo');
    if (chosen == null || !mounted) return;
    setState(() => _folder = chosen == noFolder ? null : chosen);
  }

  Future<void> _submit() async {
    final url = _url.text.trim();
    if (url.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final name = _name.text.trim();
      final sub = await ref
          .read(apiProvider)
          .subscribe(
            url.contains('://') ? url : 'https://$url',
            folderId: _folder,
            title: name.isEmpty ? null : name,
          );
      ref.invalidate(subscriptionsProvider);
      ref.invalidate(foldersProvider);
      if (!mounted) return;
      Navigator.pop(context);
      toast(context, '${sub.title} adicionado');
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = describeError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final folders = ref.watch(foldersProvider).value ?? const <Folder>[];
    String folderName = 'Sem pasta';
    for (final f in folders) {
      if (f.id == _folder) folderName = f.name;
    }
    return AlertDialog(
      title: const Text('Adicionar veículo'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _url,
              autofocus: true,
              enabled: !_busy,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: 'Endereço do site ou do feed',
                hintText: 'g1.globo.com',
                errorText: _error,
                errorMaxLines: 3,
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              enabled: !_busy,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Nome (opcional)',
                helperText: 'Vazio = o nome que o veículo usa no feed',
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _busy ? null : _chooseFolder,
              icon: const Icon(Icons.folder_outlined),
              label: Text('Pasta: $folderName'),
            ),
            if (_busy) ...[
              const SizedBox(height: 16),
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              const Text('Procurando o feed…'),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: const Text('Adicionar'),
        ),
      ],
    );
  }
}
