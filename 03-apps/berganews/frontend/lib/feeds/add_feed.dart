import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/http.dart';
import '../core/widgets.dart';
import '../data/api.dart';
import '../data/models.dart';
import 'feeds_tabs.dart';

/// "Adicionar veículo": o endereço do site ou do feed (o servidor acha o
/// feed) e, se quiser, a pasta.
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
  int? _folder;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final url = _url.text.trim();
    if (url.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final sub = await ref
          .read(apiProvider)
          .subscribe(url.contains('://') ? url : 'https://$url', folderId: _folder);
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
    return AlertDialog(
      title: const Text('Adicionar veículo'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _url,
              autofocus: true,
              enabled: !_busy,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                labelText: 'Endereço do site ou do feed',
                hintText: 'g1.globo.com',
                errorText: _error,
                errorMaxLines: 3,
              ),
              onSubmitted: (_) => _submit(),
            ),
            if (folders.isNotEmpty) ...[
              const SizedBox(height: 16),
              DropdownButtonFormField<int?>(
                initialValue: _folder,
                decoration: const InputDecoration(labelText: 'Pasta'),
                items: [
                  const DropdownMenuItem<int?>(value: null, child: Text('Sem pasta')),
                  for (final f in folders)
                    DropdownMenuItem<int?>(value: f.id, child: Text(f.name)),
                ],
                onChanged: _busy ? null : (v) => setState(() => _folder = v),
              ),
            ],
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
