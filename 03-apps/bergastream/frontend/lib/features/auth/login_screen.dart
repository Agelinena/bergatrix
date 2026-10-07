import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/routes.dart';

import '../../core/platform/app_platform.dart';
import '../../core/theme/berga_colors.dart';
import '../../core/theme/berga_text.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/auth.dart';
import '../../data/repositories/auth_repository.dart';
import 'session.dart';

/// Tela de login (Seção 2.2). Na web não tem o campo de servidor nem
/// "Continuar sem entrar".
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  late final TextEditingController _server;
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _showPassword = false;

  @override
  void initState() {
    super.initState();
    _server = TextEditingController(
      text: ref.read(sessionProvider).server ?? '',
    );
  }

  @override
  void dispose() {
    _server.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    if (ref.read(sessionProvider).status == SessionStatus.logando) return;
    ref
        .read(sessionProvider.notifier)
        .login(
          server: _server.text,
          username: _username.text,
          password: _password.text,
        );
  }

  Future<void> _continueWithoutLogin() async {
    await ref.read(sessionProvider.notifier).continueWithoutLogin();
    // O login segue acessível no modo local (para "Entrar" depois), então
    // é preciso sair dele explicitamente.
    if (mounted) context.go(AppRoutes.home);
  }

  static String messageFor(AuthError error) => switch (error) {
    AuthError.servidorNaoEncontrado =>
      'Servidor não encontrado. Confira o endereço.',
    AuthError.credenciaisInvalidas => 'Usuário ou senha incorretos.',
    AuthError.semConexao =>
      'Não foi possível conectar. Verifique sua internet.',
    AuthError.muitasTentativas =>
      'Muitas tentativas. Aguarde alguns minutos e tente de novo.',
  };

  @override
  Widget build(BuildContext context) {
    final c = BergaColors.of(context);
    final platform = ref.watch(appPlatformProvider);
    final session = ref.watch(sessionProvider);
    final error = session.loginError;
    final loading = session.status == SessionStatus.logando;
    final canRegister = ref.watch(_canRegisterProvider).value ?? false;

    Widget errorText(AuthError e) => Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(
        messageFor(e),
        style: BergaText.secondary.copyWith(color: c.ac),
      ),
    );

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: AutofillGroup(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const ScreenTitle('Bergastream', bottom: 2),
                    Text(
                      'Entre no seu servidor',
                      style: BergaText.secondary.copyWith(color: c.mu),
                    ),
                    const SizedBox(height: 22),
                    if (platform.isApp) ...[
                      const _Label('Endereço do servidor'),
                      AppTextField(
                        hint: 'https://musica.meuservidor.com',
                        controller: _server,
                        keyboardType: TextInputType.url,
                        textInputAction: TextInputAction.next,
                      ),
                      if (error == AuthError.servidorNaoEncontrado)
                        errorText(error!),
                      const SizedBox(height: 14),
                    ],
                    const _Label('Usuário'),
                    AppTextField(
                      hint: 'Seu usuário',
                      controller: _username,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.username],
                    ),
                    const SizedBox(height: 14),
                    const _Label('Senha'),
                    AppTextField(
                      hint: 'Sua senha',
                      controller: _password,
                      obscureText: !_showPassword,
                      textInputAction: TextInputAction.done,
                      autofillHints: const [AutofillHints.password],
                      onSubmitted: (_) => _submit(),
                      suffix: IconButton(
                        onPressed: () =>
                            setState(() => _showPassword = !_showPassword),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints.tightFor(
                          width: 40,
                          height: 36,
                        ),
                        icon: Icon(
                          _showPassword
                              ? Icons.visibility_off
                              : Icons.visibility,
                          size: 20,
                        ),
                        tooltip: _showPassword
                            ? 'Ocultar senha'
                            : 'Mostrar senha',
                      ),
                    ),
                    if (error != null &&
                        (error != AuthError.servidorNaoEncontrado ||
                            platform.isWeb))
                      errorText(error),
                    const SizedBox(height: 22),
                    PrimaryButton(
                      label: loading ? 'Entrando…' : 'Entrar',
                      expanded: true,
                      onPressed: loading ? null : _submit,
                    ),
                    if (canRegister) ...[
                      const SizedBox(height: 14),
                      Center(
                        child: GestureDetector(
                          onTap: () => AppToast.show(
                            context,
                            'Cadastro disponível em breve',
                          ),
                          child: Text(
                            'Criar conta',
                            style: BergaText.chipActive.copyWith(color: c.gr),
                          ),
                        ),
                      ),
                    ],
                    if (platform.isApp) ...[
                      const SizedBox(height: 14),
                      Center(
                        child: AppChip(
                          label: 'Continuar sem entrar',
                          onTap: _continueWithoutLogin,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Se o servidor permite cadastro (link "Criar conta").
final _canRegisterProvider = FutureProvider.autoDispose<bool>((ref) {
  final server = ref.watch(sessionProvider.select((s) => s.server));
  return ref.read(authRepositoryProvider).canRegister(server ?? '');
});

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        style: BergaText.secondary.copyWith(color: BergaColors.of(context).mu),
      ),
    );
  }
}
