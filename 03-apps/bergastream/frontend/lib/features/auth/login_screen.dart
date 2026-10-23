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
import '../../data/repositories/auth_repository.dart';
import 'session.dart';

/// Tela de login (Seção 2.2). Na web não tem o campo de servidor nem
/// "Continuar sem entrar".
///
/// Mostra sempre as duas formas de entrar (Authentik e usuário e senha).
/// "Conferir servidor" (no app; na web e com servidor salvo, sozinho ao
/// abrir) pergunta ao servidor quais ele aceita e esconde a que sobra. Sem
/// resposta, ficam as duas, por precaução.
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

  /// Última conferência do servidor; vale para o texto [_checkedServer]
  /// (mexer no campo volta às duas formas de entrar).
  ServerCheck? _check;
  String? _checkedServer;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    // Sem o caminho antigo dos apps 0.3.x (/api-access-bypass) no campo.
    final saved = ref.read(sessionProvider).server;
    final initial = saved != null && saved.endsWith(bypassPrefix)
        ? saved.substring(0, saved.length - bypassPrefix.length)
        : saved;
    _server = TextEditingController(text: initial ?? '');
    // Web (o próprio domínio) ou servidor já salvo: confere ao abrir.
    if (ref.read(appPlatformProvider).isWeb || (initial ?? '').isNotEmpty) {
      Future.microtask(_checkServer);
    }
  }

  /// "Conferir servidor".
  Future<void> _checkServer() async {
    if (_checking || !mounted) return;
    final text = _server.text.trim();
    final web = ref.read(appPlatformProvider).isWeb;
    if (!web && text.isEmpty) return;
    setState(() => _checking = true);
    final check = await ref.read(sessionProvider.notifier).checkServer(text);
    if (!mounted) return;
    setState(() {
      _checking = false;
      _check = check;
      _checkedServer = text;
    });
  }

  /// Opções valendo para o que está no campo agora (nulo: não conferido).
  AuthOptions? get _options =>
      _checkedServer == _server.text.trim() ? _check?.options : null;

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

  /// Linha abaixo do servidor com o resultado da conferência.
  String? _checkMessage() {
    final check = _check;
    if (check == null || _checkedServer != _server.text.trim()) return null;
    final options = check.options;
    if (options == null) {
      return '${messageFor(check.error ?? AuthError.servidorNaoEncontrado)} '
          'As duas formas de entrar continuam aqui.';
    }
    return switch ((options.oidcEnabled, options.passwordLoginEnabled)) {
      (true, true) => 'Servidor conferido: entra pelo Authentik ou com senha.',
      (true, false) => 'Servidor conferido: entra pelo Authentik.',
      (false, true) => 'Servidor conferido: entra com usuário e senha.',
      (false, false) => 'Servidor conferido.',
    };
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
    AuthError.acessoBloqueado =>
      'O servidor recusou este aparelho (bloqueio do firewall ou do '
          'CrowdSec). Fale com o administrador.',
    AuthError.certificadoInvalido =>
      'O certificado do servidor não é válido. Confira o endereço.',
  };

  @override
  Widget build(BuildContext context) {
    final c = BergaColors.of(context);
    final platform = ref.watch(appPlatformProvider);
    final session = ref.watch(sessionProvider);
    final error = session.loginError;
    final loading = session.status == SessionStatus.logando;
    final options = _options;
    // Não conferido (ou sem resposta): as duas. Conferido: só as aceitas
    // (se o servidor disser que nenhuma, mostra as duas mesmo assim).
    final none =
        options != null &&
        !options.oidcEnabled &&
        !options.passwordLoginEnabled;
    final oidc = options == null || none || options.oidcEnabled;
    final password = options == null || none || options.passwordLoginEnabled;
    final canRegister = options?.registrationEnabled ?? false;
    final checkMessage = _checkMessage();
    final checkOk = _check?.ok ?? false;

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
                        // Mexeu no endereço: volta às duas formas de entrar.
                        onChanged: (_) => setState(() {}),
                        onSubmitted: (_) => _checkServer(),
                      ),
                      if (error == AuthError.servidorNaoEncontrado)
                        errorText(error!),
                      const SizedBox(height: 10),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: AppChip(
                          label: _checking
                              ? 'Conferindo…'
                              : 'Conferir servidor',
                          icon: Icons.dns_outlined,
                          onTap: _checking ? null : _checkServer,
                        ),
                      ),
                    ],
                    if (_checking && platform.isWeb)
                      Text(
                        'Conferindo o servidor…',
                        style: BergaText.secondary.copyWith(color: c.mu),
                      ),
                    if (checkMessage != null && (platform.isApp || !checkOk))
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          checkMessage,
                          style: BergaText.secondary.copyWith(
                            color: checkOk ? c.gr : c.ac,
                          ),
                        ),
                      ),
                    const SizedBox(height: 18),
                    if (oidc)
                      PrimaryButton(
                        label: loading ? 'Entrando…' : 'Entrar com o Authentik',
                        icon: Icons.login,
                        expanded: true,
                        onPressed: loading ? null : _submitOidc,
                      ),
                    if (oidc && password)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        child: Row(
                          spacing: 10,
                          children: [
                            Expanded(child: Divider(color: c.card)),
                            Text(
                              'ou com usuário e senha',
                              style: BergaText.secondary.copyWith(color: c.mu),
                            ),
                            Expanded(child: Divider(color: c.card)),
                          ],
                        ),
                      ),
                    if (password) ...[
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
                    if (password &&
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
                    if (canRegister && password) ...[
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
