// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/app_theme.dart';
import '../../core/api_client.dart';
import '../../providers/auth_provider.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  static const _radioKey = 'radio_source';

  String _radioSource = 'lastfm';

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
    _currentPwCtrl.dispose();
    _newPwCtrl.dispose();
    _confirmPwCtrl.dispose();
    super.dispose();
  }

  void _loadPrefs() {
    try {
      final stored = html.window.localStorage[_radioKey];
      if (stored != null) setState(() => _radioSource = stored);
    } catch (_) {}
  }

  void _setRadioSource(String source) {
    setState(() => _radioSource = source);
    try {
      html.window.localStorage[_radioKey] = source;
    } catch (_) {}
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

  String _extractError(Object e) {
    try {
      final dynamic err = e;
      final detail = err?.response?.data?['detail'];
      if (detail is String) return detail;
    } catch (_) {}
    return 'Erro ao alterar senha';
  }

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
