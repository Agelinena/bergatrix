import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import 'session.dart';

/// Login: só pelo Authentik. Fora da web, a pessoa digita o endereço do
/// servidor uma vez (fica guardado).
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  late final TextEditingController _server;

  @override
  void initState() {
    super.initState();
    final saved = ref.read(sessionProvider).server ?? '';
    _server = TextEditingController(
      text: saved.replaceFirst(RegExp('^https://'), ''),
    );
  }

  @override
  void dispose() {
    _server.dispose();
    super.dispose();
  }

  void _login() =>
      ref.read(sessionProvider.notifier).loginWithOidc(_server.text);

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final busy = session.status == SessionStatus.loggingIn;
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 88,
                      height: 88,
                      decoration: BoxDecoration(
                        color: brandBlue,
                        borderRadius: BorderRadius.circular(22),
                      ),
                      child: const Icon(Icons.newspaper, color: Colors.white, size: 52),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Berganews',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'As notícias da família, sem anúncio, com a mesma história contada por vários veículos.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 32),
                  if (!kIsWeb) ...[
                    TextField(
                      controller: _server,
                      enabled: !busy,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: 'Servidor',
                        hintText: 'news.example.com',
                        prefixIcon: Icon(Icons.dns_outlined),
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => _login(),
                    ),
                    const SizedBox(height: 16),
                  ],
                  FilledButton.icon(
                    onPressed: busy ? null : _login,
                    icon: busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.login),
                    label: Text(busy ? 'Entrando…' : 'Entrar com o Authentik'),
                  ),
                  if (session.error != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      session.error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
