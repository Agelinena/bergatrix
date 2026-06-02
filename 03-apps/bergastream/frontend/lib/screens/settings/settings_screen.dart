import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/error_messages.dart';
import '../../core/storage.dart';
import '../../core/theme/app_theme.dart';
import '../../core/api_client.dart';
import '../../models/track.dart';
import '../../models/user.dart';
import '../../providers/auth_provider.dart';
import '../../providers/library_provider.dart';
import '../../providers/playback_settings_provider.dart';
import '../../services/offline_service.dart';
import 'logs_screen.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  static const _radioKey = 'radio_source';

  String _radioSource = 'lastfm';

  // Username change form
  final _usernameFormKey = GlobalKey<FormState>();
  final _usernameCtrl = TextEditingController();
  bool _savingUsername = false;

  // Password change form
  final _formKey = GlobalKey<FormState>();
  final _currentPwCtrl = TextEditingController();
  final _newPwCtrl = TextEditingController();
  final _confirmPwCtrl = TextEditingController();
  bool _obscureCurrent = true;
  bool _obscureNew = true;
  bool _obscureConfirm = true;
  bool _savingPw = false;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  @override
  void dispose() {
    _usernameCtrl.dispose();
    _currentPwCtrl.dispose();
    _newPwCtrl.dispose();
    _confirmPwCtrl.dispose();
    super.dispose();
  }

  void _loadPrefs() {
    // Pre-fill username field with current value
    final user = ref.read(authProvider).valueOrNull;
    if (user != null) _usernameCtrl.text = user.username;
    // Load radio source preference asynchronously
    AppStorage.getString(_radioKey).then((stored) {
      if (stored != null && mounted) setState(() => _radioSource = stored);
    });
  }

  void _setRadioSource(String source) {
    setState(() => _radioSource = source);
    AppStorage.setString(_radioKey, source).ignore();
  }

  Future<void> _changeUsername() async {
    if (!(_usernameFormKey.currentState?.validate() ?? false)) return;
    setState(() => _savingUsername = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(authProvider.notifier).updateUsername(_usernameCtrl.text.trim());
      messenger.showSnackBar(
        const SnackBar(content: Text('Nome de usuário atualizado com sucesso')),
      );
    } catch (e) {
      final msg = _extractError(e);
      messenger.showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _savingUsername = false);
    }
  }

  Future<void> _changePassword() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _savingPw = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(apiClientProvider).changePassword(
        _currentPwCtrl.text,
        _newPwCtrl.text,
      );
      _currentPwCtrl.clear();
      _newPwCtrl.clear();
      _confirmPwCtrl.clear();
      messenger.showSnackBar(
        const SnackBar(content: Text('Senha alterada com sucesso')),
      );
    } catch (e) {
      final msg = _extractError(e);
      messenger.showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _savingPw = false);
    }
  }

  String _extractError(Object e) => friendlyError(e, fallback: 'Algo deu errado. Tente novamente.');

  Future<void> _logout() async {
    await ref.read(authProvider.notifier).logout();
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authProvider).valueOrNull;

    return Scaffold(
      appBar: AppBar(title: const Text('Configurações')),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          // ── Conta ──────────────────────────────────────────────────────
          _SectionHeader('Conta'),
          if (user != null)
            ListTile(
              leading: CircleAvatar(
                backgroundColor: AppColors.primary,
                child: Text(
                  user.username.isNotEmpty ? user.username[0].toUpperCase() : '?',
                  style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
                ),
              ),
              title: Text(user.username),
              subtitle: Text(user.email, style: const TextStyle(color: AppColors.textSecondary)),
            ),
          const SizedBox(height: 8),

          // ── Nome de usuário ────────────────────────────────────────────
          _SectionHeader('Nome de usuário'),
          const SizedBox(height: 8),
          Form(
            key: _usernameFormKey,
            child: Column(
              children: [
                TextFormField(
                  controller: _usernameCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Nome de usuário',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) return 'Obrigatório';
                    if (v.trim().length < 3) return 'Mínimo 3 caracteres';
                    if (v.trim().length > 32) return 'Máximo 32 caracteres';
                    if (!RegExp(r'^[a-zA-Z0-9_.-]+$').hasMatch(v.trim())) {
                      return 'Apenas letras, números, _ . -';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _savingUsername ? null : _changeUsername,
                    child: _savingUsername
                        ? const SizedBox(
                            height: 18, width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                        : const Text('Salvar nome de usuário'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // ── Rádio ──────────────────────────────────────────────────────
          _SectionHeader('Modo Rádio'),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Text(
              'Fonte usada para sugerir músicas quando o rádio está ativo.',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
            ),
          ),
          const SizedBox(height: 8),
          _RadioSourceSelector(
            value: _radioSource,
            onChanged: _setRadioSource,
          ),
          const SizedBox(height: 24),

          // ── Reprodução ─────────────────────────────────────────────────
          _SectionHeader('Reprodução'),
          const _CrossfadeTile(),
          const SizedBox(height: 24),

          // ── Segurança ──────────────────────────────────────────────────
          _SectionHeader('Segurança'),
          const SizedBox(height: 8),
          Form(
            key: _formKey,
            child: Column(
              children: [
                _PwField(
                  controller: _currentPwCtrl,
                  label: 'Senha atual',
                  obscure: _obscureCurrent,
                  onToggle: () => setState(() => _obscureCurrent = !_obscureCurrent),
                  validator: (v) => (v == null || v.isEmpty) ? 'Obrigatório' : null,
                ),
                const SizedBox(height: 12),
                _PwField(
                  controller: _newPwCtrl,
                  label: 'Nova senha',
                  obscure: _obscureNew,
                  onToggle: () => setState(() => _obscureNew = !_obscureNew),
                  validator: (v) {
                    if (v == null || v.isEmpty) return 'Obrigatório';
                    if (v.length < 8) return 'Mínimo 8 caracteres';
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                _PwField(
                  controller: _confirmPwCtrl,
                  label: 'Confirmar nova senha',
                  obscure: _obscureConfirm,
                  onToggle: () => setState(() => _obscureConfirm = !_obscureConfirm),
                  validator: (v) {
                    if (v != _newPwCtrl.text) return 'As senhas não coincidem';
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _savingPw ? null : _changePassword,
                    child: _savingPw
                        ? const SizedBox(
                            height: 18, width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                        : const Text('Alterar senha'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),

          // ── Importar playlist ──────────────────────────────────────────
          _SectionHeader('Importar playlist'),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Text(
              'Cole o link de uma playlist do Spotify, Deezer ou YouTube.',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
            ),
          ),
          const SizedBox(height: 8),
          Card(
            margin: const EdgeInsets.symmetric(vertical: 4),
            color: AppColors.surfaceVariant,
            child: ListTile(
              leading: const Icon(Icons.playlist_add, color: AppColors.primary),
              title: const Text('Importar do Spotify / Deezer / YouTube'),
              subtitle: const Text(
                'Cole o link de qualquer playlist pública',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _showImportPlaylistDialog(context),
            ),
          ),
          const SizedBox(height: 24),

          // ── Admin ──────────────────────────────────────────────────────
          if (user?.isAdmin == true) ...[
            _SectionHeader('Administração'),
            Card(
              margin: const EdgeInsets.symmetric(vertical: 4),
              color: AppColors.surfaceVariant,
              child: ListTile(
                leading: const Icon(Icons.admin_panel_settings, color: AppColors.primary),
                title: const Text('Gerenciar usuários'),
                subtitle: const Text(
                  'Criar, desativar e definir permissões',
                  style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _showAdminPanel(context),
              ),
            ),
            const SizedBox(height: 24),
          ],

          // ── Armazenamento offline ──────────────────────────────────────
          const Divider(),
          _SectionHeader('Armazenamento offline'),
          const _OfflineStorageTile(),

          // ── Diagnóstico ────────────────────────────────────────────────
          const Divider(),
          _SectionHeader('Diagnóstico'),
          ListTile(
            leading: const Icon(Icons.bug_report_outlined),
            title: const Text('Logs do app'),
            subtitle: const Text(
              'Veja o que o app registrou em memória — útil para reportar bugs',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const LogsScreen()),
              );
            },
          ),

          // ── Sair ───────────────────────────────────────────────────────
          const Divider(),
          ListTile(
            leading: const Icon(Icons.logout, color: Colors.red),
            title: const Text('Sair', style: TextStyle(color: Colors.red)),
            onTap: _logout,
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  void _showAdminPanel(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => const _AdminPanelDialog(),
    );
  }

  void _showImportPlaylistDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => _ImportPlaylistDialog(
        onImported: () => ref.read(libraryProvider.notifier).load(),
      ),
    );
  }
}

class _OfflineStorageTile extends StatefulWidget {
  const _OfflineStorageTile();

  @override
  State<_OfflineStorageTile> createState() => _OfflineStorageTileState();
}

class _OfflineStorageTileState extends State<_OfflineStorageTile> {
  String? _path;
  int _bytes = 0;
  int _count = 0;
  bool _loading = true;
  bool _clearing = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final path = await OfflineService.downloadsDirectory();
    final bytes = await OfflineService.diskUsageBytes();
    final count = await OfflineService.fileCount();
    if (!mounted) return;
    setState(() {
      _path = path;
      _bytes = bytes;
      _count = count;
      _loading = false;
    });
  }

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceVariant,
        title: const Text('Apagar downloads offline?'),
        content: Text('Vai apagar $_count arquivo(s) '
            '(${OfflineService.formatBytes(_bytes)}). '
            'Você terá que baixar de novo para ouvir offline.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Apagar')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _clearing = true);
    final deleted = await OfflineService.clearAll();
    if (!mounted) return;
    setState(() => _clearing = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$deleted arquivo(s) apagados.')),
    );
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const ListTile(
        leading: Icon(Icons.folder_outlined),
        title: Text('Carregando...'),
      );
    }
    if (_path == null) {
      // Web — no local storage.
      return const ListTile(
        leading: Icon(Icons.folder_outlined),
        title: Text('Downloads locais'),
        subtitle: Text(
          'No navegador, os arquivos não ficam no dispositivo. '
          'Use o app Android para baixar offline.',
          style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          leading: const Icon(Icons.folder_outlined),
          title: Text('$_count faixa(s) baixada(s)'),
          subtitle: Text(
            'Ocupa ${OfflineService.formatBytes(_bytes)}',
            style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
          ),
          trailing: IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Recarregar',
            onPressed: _refresh,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.surface,
              border: Border.all(color: AppColors.surfaceVariant),
              borderRadius: BorderRadius.circular(6),
            ),
            child: SelectableText(
              _path!,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: OutlinedButton.icon(
            onPressed: _bytes == 0 || _clearing ? null : _confirmClear,
            icon: _clearing
                ? const SizedBox(
                    width: 14, height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.redAccent))
                : const Icon(Icons.delete_outline, color: Colors.redAccent, size: 18),
            label: const Text(
              'Apagar todos os downloads',
              style: TextStyle(color: Colors.redAccent),
            ),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Colors.redAccent),
              shape: const StadiumBorder(),
            ),
          ),
        ),
      ],
    );
  }
}

class _CrossfadeTile extends ConsumerWidget {
  const _CrossfadeTile();

  String _format(int ms) {
    if (ms <= 0) return 'Desligado';
    if (ms < 1000) return '${ms}ms';
    final seconds = ms / 1000.0;
    if (seconds == seconds.roundToDouble()) return '${seconds.toInt()}s';
    return '${seconds.toStringAsFixed(1)}s';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(playbackSettingsProvider);
    final notifier = ref.read(playbackSettingsProvider.notifier);
    final value = settings.crossfadeMs;
    final maxMs = PlaybackSettingsNotifier.maxCrossfadeMs;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      color: AppColors.surfaceVariant,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.graphic_eq, color: AppColors.primary),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text('Crossfade',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                ),
                Text(
                  _format(value),
                  style: const TextStyle(
                      color: AppColors.primary, fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'Mistura o final de uma música com o começo da próxima.',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
            ),
            Slider(
              min: 0,
              max: maxMs.toDouble(),
              divisions: maxMs ~/ 500,
              value: value.toDouble().clamp(0.0, maxMs.toDouble()),
              activeColor: AppColors.primary,
              label: _format(value),
              onChanged: (v) => notifier.setCrossfadeMs(v.round()),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
          color: AppColors.primary,
          fontSize: 11,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

class _RadioSourceSelector extends StatelessWidget {
  final String value;
  final void Function(String) onChanged;

  const _RadioSourceSelector({required this.value, required this.onChanged});

  static const _options = [
    ('lastfm', 'Last.fm', Icons.music_note, 'Músicas similares via Last.fm (recomendado)'),
    ('ai', 'IA', Icons.auto_awesome, 'Sugestões geradas por IA'),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      children: _options.map((opt) {
        final (src, label, icon, desc) = opt;
        final selected = value == src;
        return Card(
          margin: const EdgeInsets.symmetric(vertical: 4),
          color: selected ? AppColors.primary.withOpacity(0.12) : AppColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: selected
                ? const BorderSide(color: AppColors.primary, width: 1.5)
                : BorderSide.none,
          ),
          child: ListTile(
            leading: Icon(icon, color: selected ? AppColors.primary : AppColors.textSecondary),
            title: Text(label,
                style: TextStyle(
                  color: selected ? AppColors.primary : AppColors.textPrimary,
                  fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                )),
            subtitle: Text(desc,
                style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
            trailing: selected
                ? const Icon(Icons.check_circle, color: AppColors.primary)
                : null,
            onTap: () => onChanged(src),
          ),
        );
      }).toList(),
    );
  }
}

class _PwField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final bool obscure;
  final VoidCallback onToggle;
  final String? Function(String?) validator;

  const _PwField({
    required this.controller,
    required this.label,
    required this.obscure,
    required this.onToggle,
    required this.validator,
  });

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      obscureText: obscure,
      validator: validator,
      decoration: InputDecoration(
        labelText: label,
        suffixIcon: IconButton(
          icon: Icon(obscure ? Icons.visibility_off : Icons.visibility, size: 20),
          onPressed: onToggle,
        ),
      ),
    );
  }
}

// ── Import Playlist Dialog ─────────────────────────────────────────────────────

class _ImportPlaylistDialog extends ConsumerStatefulWidget {
  final VoidCallback onImported;
  const _ImportPlaylistDialog({required this.onImported});

  @override
  ConsumerState<_ImportPlaylistDialog> createState() => _ImportPlaylistDialogState();
}

class _ImportPlaylistDialogState extends ConsumerState<_ImportPlaylistDialog> {
  final _urlCtrl = TextEditingController();
  bool _loading = false;
  String? _resolvedName;
  List<Track> _resolvedTracks = [];

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

  Future<void> _resolve() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) return;
    setState(() { _loading = true; _resolvedName = null; _resolvedTracks = []; });
    try {
      final client = ref.read(apiClientProvider);
      final data = await client.resolvePlaylistUrl(url);
      final name = data['name'] as String;
      final tracks = (data['tracks'] as List<dynamic>)
          .map((t) => Track.fromJson(t as Map<String, dynamic>))
          .toList();
      setState(() {
        _resolvedName = name;
        _resolvedTracks = tracks;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(friendlyError(e)), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _import() async {
    if (_resolvedName == null || _resolvedTracks.isEmpty) return;
    setState(() => _loading = true);
    try {
      final client = ref.read(apiClientProvider);
      // 1. Create playlist
      final pl = await client.createPlaylist(_resolvedName!);
      final playlistId = pl['id'] as String;
      // 2. Register + add tracks
      for (final track in _resolvedTracks) {
        try {
          await client.registerTrack(track.toJson());
          await client.addTrackToPlaylist(playlistId, track.id, force: false);
        } catch (_) {}
      }
      // 3. Dispara download permanente em background (fire-and-forget)
      client.downloadPlaylistPermanent(playlistId).ignore();
      widget.onImported();
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('"$_resolvedName" importada com ${_resolvedTracks.length} músicas! Download iniciado em background.'),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(friendlyError(e)), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.surface,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Importar playlist',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _urlCtrl,
                      decoration: const InputDecoration(
                        hintText: 'Link do Spotify, Deezer ou YouTube',
                        prefixIcon: Icon(Icons.link),
                        isDense: true,
                      ),
                      onSubmitted: (_) => _resolve(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _loading ? null : _resolve,
                    child: _loading && _resolvedName == null
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                        : const Text('Buscar'),
                  ),
                ],
              ),
              if (_resolvedName != null) ...[
                const SizedBox(height: 20),
                const Divider(height: 1),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Icon(Icons.playlist_play, color: AppColors.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_resolvedName!,
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                          Text('${_resolvedTracks.length} músicas',
                              style: const TextStyle(color: AppColors.textSecondary, fontSize: 13)),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // Preview of first few tracks
                if (_resolvedTracks.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  SizedBox(
                    height: 140,
                    child: ListView.builder(
                      itemCount: _resolvedTracks.take(6).length,
                      itemBuilder: (_, i) {
                        final t = _resolvedTracks[i];
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Text('${i + 1}', style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                          title: Text(t.title, style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis),
                          subtitle: Text(t.artist, style: const TextStyle(color: AppColors.textSecondary, fontSize: 11), overflow: TextOverflow.ellipsis),
                        );
                      },
                    ),
                  ),
                  if (_resolvedTracks.length > 6)
                    Text('... e mais ${_resolvedTracks.length - 6} músicas',
                        style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                ],
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _loading ? null : _import,
                    icon: _loading
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                        : const Icon(Icons.download),
                    label: const Text('Importar playlist'),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancelar'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Admin Panel Dialog ─────────────────────────────────────────────────────────

class _AdminPanelDialog extends ConsumerStatefulWidget {
  const _AdminPanelDialog();

  @override
  ConsumerState<_AdminPanelDialog> createState() => _AdminPanelDialogState();
}

class _AdminPanelDialogState extends ConsumerState<_AdminPanelDialog> {
  List<AppUser> _users = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final data = await ref.read(apiClientProvider).adminListUsers();
      setState(() {
        _users = data
            .map((u) => AppUser.fromJson(u as Map<String, dynamic>))
            .toList();
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  Future<void> _toggleAdmin(AppUser user) async {
    try {
      await ref.read(apiClientProvider).adminUpdateUser(user.id, isAdmin: !user.isAdmin);
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(friendlyError(e)), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _toggleActive(AppUser user) async {
    try {
      await ref.read(apiClientProvider).adminUpdateUser(user.id, isActive: !user.isActive);
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(friendlyError(e)), backgroundColor: Colors.red),
        );
      }
    }
  }

  void _showCreateUser() {
    showDialog(
      context: context,
      builder: (_) => _CreateUserDialog(onCreated: _load),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.surface,
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600, maxHeight: 700),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
              child: Row(
                children: [
                  const Icon(Icons.admin_panel_settings, color: AppColors.primary),
                  const SizedBox(width: 12),
                  const Text(
                    'Gerenciar Usuários',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    onPressed: _load,
                    tooltip: 'Atualizar',
                  ),
                  IconButton(
                    icon: const Icon(Icons.person_add),
                    onPressed: _showCreateUser,
                    tooltip: 'Criar usuário',
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),

            // User list
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator(color: AppColors.primary))
                  : _users.isEmpty
                      ? const Center(child: Text('Nenhum usuário encontrado'))
                      : ListView.separated(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          itemCount: _users.length,
                          separatorBuilder: (_, __) => const Divider(height: 1, indent: 16),
                          itemBuilder: (_, i) {
                            final u = _users[i];
                            return ListTile(
                              leading: CircleAvatar(
                                backgroundColor: u.isAdmin
                                    ? AppColors.primary
                                    : AppColors.surfaceVariant,
                                child: Text(
                                  u.initials,
                                  style: TextStyle(
                                    color: u.isAdmin ? Colors.black : AppColors.textPrimary,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              title: Row(
                                children: [
                                  Text(u.username, style: const TextStyle(fontWeight: FontWeight.w600)),
                                  const SizedBox(width: 8),
                                  if (u.isAdmin)
                                    _Chip('Admin', AppColors.primary),
                                  if (!u.isActive)
                                    _Chip('Inativo', Colors.red),
                                ],
                              ),
                              subtitle: Text(u.email,
                                  style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                              trailing: PopupMenuButton<String>(
                                icon: const Icon(Icons.more_vert),
                                color: AppColors.surfaceVariant,
                                onSelected: (val) {
                                  if (val == 'admin') _toggleAdmin(u);
                                  if (val == 'active') _toggleActive(u);
                                },
                                itemBuilder: (_) => [
                                  PopupMenuItem(
                                    value: 'admin',
                                    child: Text(u.isAdmin ? 'Remover admin' : 'Tornar admin'),
                                  ),
                                  PopupMenuItem(
                                    value: 'active',
                                    child: Text(u.isActive ? 'Desativar conta' : 'Reativar conta'),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final Color color;
  const _Chip(this.label, this.color);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _CreateUserDialog extends ConsumerStatefulWidget {
  final VoidCallback onCreated;
  const _CreateUserDialog({required this.onCreated});

  @override
  ConsumerState<_CreateUserDialog> createState() => _CreateUserDialogState();
}

class _CreateUserDialogState extends ConsumerState<_CreateUserDialog> {
  final _formKey = GlobalKey<FormState>();
  final _usernameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _isAdmin = false;
  bool _saving = false;
  bool _obscurePassword = true;

  @override
  void dispose() {
    _usernameCtrl.dispose();
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    try {
      await ref.read(apiClientProvider).adminCreateUser(
        username: _usernameCtrl.text.trim(),
        email: _emailCtrl.text.trim(),
        password: _passwordCtrl.text,
        isAdmin: _isAdmin,
      );
      if (mounted) {
        Navigator.of(context).pop();
        widget.onCreated();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Usuário criado com sucesso')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(friendlyError(e)), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.surface,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Criar usuário',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 20),
                TextFormField(
                  controller: _usernameCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Nome de usuário',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) return 'Obrigatório';
                    if (v.trim().length < 3) return 'Mínimo 3 caracteres';
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _emailCtrl,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    labelText: 'E-mail',
                    prefixIcon: Icon(Icons.email_outlined),
                  ),
                  validator: (v) {
                    if (v == null || !v.contains('@')) return 'E-mail inválido';
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _passwordCtrl,
                  obscureText: _obscurePassword,
                  decoration: InputDecoration(
                    labelText: 'Senha',
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: IconButton(
                      icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility, size: 20),
                      onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                    ),
                  ),
                  validator: (v) {
                    if (v == null || v.length < 8) return 'Mínimo 8 caracteres';
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Permissão de administrador'),
                  value: _isAdmin,
                  activeColor: AppColors.primary,
                  onChanged: (v) => setState(() => _isAdmin = v),
                ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Cancelar'),
                    ),
                    const SizedBox(width: 12),
                    FilledButton(
                      onPressed: _saving ? null : _submit,
                      child: _saving
                          ? const SizedBox(
                              height: 18, width: 18,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                          : const Text('Criar'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
