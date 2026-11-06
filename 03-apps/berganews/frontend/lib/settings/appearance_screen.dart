import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/format.dart';
import '../core/http.dart';
import '../core/prefs.dart';
import '../core/widgets.dart';
import '../data/models.dart';

/// Painel Aparência: quais abas aparecem e em que ordem, tema, texto.
class AppearanceScreen extends ConsumerWidget {
  const AppearanceScreen({super.key});

  static List<TabPref> _move(List<TabPref> tabs, int from, int to) {
    final list = [...tabs];
    final moved = list.removeAt(from);
    list.insert(to, moved);
    return list;
  }

  Future<void> _save(BuildContext context, WidgetRef ref, Prefs prefs) async {
    try {
      await ref.read(prefsProvider.notifier).save(prefs);
    } on Object catch (e) {
      if (context.mounted) toast(context, describeError(e));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(prefsProvider).value ?? Prefs.defaults;
    final theme = Theme.of(context);
    final enabled = prefs.tabs.where((t) => t.enabled && t.available).length;

    Widget header(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Text(
        text,
        style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary),
      ),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Aparência')),
      body: ListView(
        children: [
          header('Abas'),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text('Ligue as que quiser e use as setas para mudar a ordem.'),
          ),
          for (var i = 0; i < prefs.tabs.length; i++)
            ListTile(
              key: ValueKey(prefs.tabs[i].id),
              leading: Switch(
                value: prefs.tabs[i].enabled && prefs.tabs[i].available,
                // A última aba ligada não desliga: o app precisa de uma.
                onChanged:
                    !prefs.tabs[i].available ||
                        (prefs.tabs[i].enabled && enabled <= 1)
                    ? null
                    : (v) {
                        final tabs = [...prefs.tabs];
                        tabs[i] = tabs[i].copyWith(enabled: v);
                        _save(context, ref, prefs.copyWith(tabs: tabs));
                      },
              ),
              title: Text(prefs.tabs[i].id.label),
              subtitle: prefs.tabs[i].available
                  ? null
                  : const Text('Ainda não disponível neste servidor'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Subir',
                    onPressed: i == 0
                        ? null
                        : () => _save(context, ref, prefs.copyWith(tabs: _move(prefs.tabs, i, i - 1))),
                    icon: const Icon(Icons.arrow_upward),
                  ),
                  IconButton(
                    tooltip: 'Descer',
                    onPressed: i == prefs.tabs.length - 1
                        ? null
                        : () => _save(context, ref, prefs.copyWith(tabs: _move(prefs.tabs, i, i + 1))),
                    icon: const Icon(Icons.arrow_downward),
                  ),
                ],
              ),
            ),
          header('Tema'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'system', label: Text('Sistema')),
                ButtonSegment(value: 'light', label: Text('Claro')),
                ButtonSegment(value: 'dark', label: Text('Escuro')),
              ],
              selected: {prefs.theme},
              onSelectionChanged: (s) =>
                  _save(context, ref, prefs.copyWith(theme: s.first)),
            ),
          ),
          header('Texto do leitor'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Slider(
              value: prefs.textScale.clamp(0.8, 1.6).toDouble(),
              min: 0.8,
              max: 1.6,
              divisions: 8,
              label: '${(prefs.textScale * 100).round()}%',
              // Mostra enquanto arrasta; grava ao soltar.
              onChanged: (v) => ref
                  .read(prefsProvider.notifier)
                  .preview(prefs.copyWith(textScale: v)),
              onChangeEnd: (v) =>
                  _save(context, ref, prefs.copyWith(textScale: v)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Assim fica o texto das matérias.',
              style: theme.textTheme.bodyLarge?.copyWith(
                fontSize: 17 * prefs.textScale,
                height: 1.6,
              ),
            ),
          ),
          header('Leitura'),
          ListTile(
            title: const Text('Idioma de leitura'),
            subtitle: const Text('O botão de traduzir leva para este idioma'),
            trailing: DropdownButton<String>(
              value: prefs.language,
              items: [
                for (final code in const ['pt', 'en'])
                  DropdownMenuItem(value: code, child: Text(languageName(code))),
              ],
              onChanged: (v) {
                if (v != null) _save(context, ref, prefs.copyWith(language: v));
              },
            ),
          ),
          SwitchListTile(
            title: const Text('Marcar como lida ao abrir'),
            value: prefs.markReadOnOpen,
            onChanged: (v) =>
                _save(context, ref, prefs.copyWith(markReadOnOpen: v)),
          ),
          SwitchListTile(
            title: const Text('Abrir no site em vez do leitor'),
            subtitle: const Text('Para quem prefere a página original'),
            value: prefs.openOriginal,
            onChanged: (v) =>
                _save(context, ref, prefs.copyWith(openOriginal: v)),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}
