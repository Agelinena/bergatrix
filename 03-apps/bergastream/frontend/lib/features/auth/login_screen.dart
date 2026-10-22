import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/routes.dart';

import '../../core/network/api_error.dart';
import '../../core/platform/app_platform.dart';
import '../../core/theme/berga_colors.dart';
import '../../core/theme/berga_text.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/auth.dart';
import 'session.dart';

/// Tela de login (Seção 2.2). Na web não tem o campo de servidor nem
/// "Continuar sem entrar". Com o Authentik no servidor, o login principal é
/// "Entrar com o Authentik"; usuário e senha ficam recolhidos (ou somem, se
/// o servidor desligou o login por senha).
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

  /// "Entrar com usuário e senha" aberto (quando há Authentik).
  bool _passwordOpen = false;

  /// Servidor cujas opções de login valem (muda ao sair do campo).
  String? _optionsServer;

  /// Últimas opções recebidas: valem enquanto as do endereço novo chegam.
  AuthOptions? _lastOptions;
  bool _gotOptions = false;

  @override
  void initState() {
    super.initState();
    _optionsServer = ref.read(sessionProvider).server;
    _server = TextEditingController(text: _optionsServer ?? '');
  }

  void _serverChanged() {
    final text = _server.text.trim();
    if (text.isNotEmpty && text != _optionsServer) {
      setState(() => _optionsServer = text);
    }
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

  void _submitOidc() {
    if (ref.read(sessionProvider).status == SessionStatus.logando) return;
    ref.read(sessionProvider.notifier).loginWithOidc(server: _server.text);
  }

  /// Pede o link de redefinir senha (vai para o e-mail da conta).
  Future<void> _forgot() async {
    final result = await showFormDialog(
      context,
      title: 'Esqueci minha senha',
      confirmLabel: 'Enviar link',
      note:
          'O link para criar uma senha nova vai para o e-mail cadastrado na '
          'sua conta.',
      fields: [
        FormFieldSpec(
          'Usuário ou e-mail',
          initial: _username.text.trim(),
          keyboardType: TextInputType.emailAddress,
        ),
      ],
    );
    if (result == null || !mounted) return;
    String message;
    try {
      await ref
          .read(sessionProvider.notifier)
          .forgotPassword(server: _server.text, login: result.values.single);
      message =
          'Se a conta tiver e-mail, o link chega em instantes. Confira também '
          'o spam.';
    } on ApiException catch (e) {
      message = e.serverMessage;
    } on AuthException catch (e) {
      message = messageFor(e.error);
    }
    if (mounted) AppToast.show(context, message);
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
    AuthError.useAuthentik =>
      'Este servidor usa o login pelo Authentik. Toque em "Entrar com o '
          'Authentik".',
    AuthError.semAuthentik =>
      'Este servidor não tem login pelo Authentik. Entre com usuário e senha.',
    AuthError.authentikFalhou =>
      'O login pelo Authentik não terminou. Tente de novo.',
  };

  @override
  Widget build(BuildContext context) {
    final c = BergaColors.of(context);
    final platform = ref.watch(appPlatformProvider);
    final session = ref.watch(sessionProvider);
    final error = session.loginError;
    final loading = session.status == SessionStatus.logando;
    final optionsAsync = ref.watch(_loginOptionsProvider(_optionsServer));
    if (optionsAsync.hasValue) {
      _lastOptions = optionsAsync.value;
      _gotOptions = true;
    }
    // Só na primeira consulta: depois valem as últimas opções.
    final checking = !_gotOptions;
    final options = _lastOptions;
    // Servidor ainda não informado (app): mostra os dois jeitos, abertos.
    final oidc = !checking && (options?.oidcEnabled ?? true);
    final password = !checking && (options?.passwordLoginEnabled ?? true);
    final canRegister = options?.registrationEnabled ?? false;
    final showForm = password && (!oidc || _passwordOpen || options == null);

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
                      Focus(
                        onFocusChange: (focused) {
                          if (!focused) _serverChanged();
                        },
                        child: AppTextField(
                          hint: 'https://musica.meuservidor.com',
                          controller: _server,
                          keyboardType: TextInputType.url,
                          textInputAction: TextInputAction.next,
                          onSubmitted: (_) => _serverChanged(),
                        ),
                      ),
                      if (error == AuthError.servidorNaoEncontrado)
                        errorText(error!),
                      const SizedBox(height: 14),
                    ],
                    if (checking)
                      const Center(
                        child: Padding(
                          padding: EdgeInsets.all(12),
                          child: CircularProgressIndicator(),
                        ),
                      ),
                    if (oidc) ...[
                      PrimaryButton(
                        label: loading ? 'Entrando…' : 'Entrar com o Authentik',
                        icon: Icons.login,
                        expanded: true,
                        onPressed: loading ? null : _submitOidc,
                      ),
                      if (password && !showForm) ...[
                        const SizedBox(height: 14),
                        Center(
                          child: AppChip(
                            label: 'Entrar com usuário e senha',
                            onTap: () => setState(() => _passwordOpen = true),
                          ),
                        ),
                      ],
                      if (showForm) const SizedBox(height: 22),
                    ],
                    if (showForm) ...[
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
                      const SizedBox(height: 22),
                      PrimaryButton(
                        label: loading ? 'Entrando…' : 'Entrar',
                        expanded: true,
                        onPressed: loading ? null : _submit,
                      ),
                    ],
                    if (error != null &&
                        (error != AuthError.servidorNaoEncontrado ||
                            platform.isWeb))
                      errorText(error),
                    if (showForm &&
                        (options?.passwordResetEnabled ?? false)) ...[
                      const SizedBox(height: 14),
                      Center(
                        child: GestureDetector(
                          onTap: _forgot,
                          child: Text(
                            'Esqueci minha senha',
                            style: BergaText.chipActive.copyWith(color: c.gr),
                          ),
                        ),
                      ),
                    ],
                    if (canRegister && showForm) ...[
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

/// Como o servidor aceita o login (nulo: servidor ainda não informado).
final _loginOptionsProvider = FutureProvider.autoDispose
    .family<AuthOptions?, String?>((ref, server) async {
      final web = ref.read(appPlatformProvider).isWeb;
      if (!web && (server == null || server.trim().isEmpty)) return null;
      return ref.read(sessionProvider.notifier).loginOptions(server);
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
