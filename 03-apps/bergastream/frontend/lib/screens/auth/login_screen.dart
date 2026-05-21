import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/constants.dart';
import '../../core/theme/app_theme.dart';
import '../../providers/auth_provider.dart';
import '../../widgets/berga_logo.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _loading = false;
  bool _testing = false;
  String? _error;
  String? _diag;

  Future<void> _testConnection() async {
    setState(() { _testing = true; _diag = null; _error = null; });
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 8),
    ));
    final url = '$kApiBaseUrl/api/health';
    final stopwatch = Stopwatch()..start();
    try {
      final resp = await dio.get(url);
      stopwatch.stop();
      setState(() {
        _diag = 'OK ${resp.statusCode} em ${stopwatch.elapsedMilliseconds}ms\n'
            'Body: ${resp.data}';
      });
    } on DioException catch (e) {
      stopwatch.stop();
      final detail = StringBuffer()
        ..writeln('Tipo: ${e.type.name}')
        ..writeln('Mensagem: ${e.message}')
        ..writeln('URL: $url')
        ..writeln('Tempo: ${stopwatch.elapsedMilliseconds}ms');
      if (e.response != null) {
        detail
          ..writeln('Status: ${e.response?.statusCode}')
          ..writeln('Resp: ${e.response?.data}');
      }
      if (e.error != null) {
        detail.writeln('Erro: ${e.error}');
      }
      setState(() => _diag = 'FALHOU\n$detail');
      debugPrint('[Login] /health test failed: $detail');
    } catch (e) {
      stopwatch.stop();
      setState(() => _diag = 'EXCEÇÃO\n$e');
      debugPrint('[Login] /health test threw: $e');
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  /// Maps the various failure modes into a user-readable message AND prints
  /// the underlying error to logcat so we can debug what's actually going wrong.
  String _humanizeLoginError(Object e) {
    debugPrint('[Login] error: $e');
    if (e is DioException) {
      switch (e.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
          return 'O servidor demorou demais para responder.\n'
              'Verifique sua conexão e o endereço da API.';
        case DioExceptionType.connectionError:
        case DioExceptionType.unknown:
          return 'Não consegui conectar ao servidor.\n'
              'API: $kApiBaseUrl\n'
              'Detalhe: ${e.message ?? e.error ?? e.type.name}';
        case DioExceptionType.badCertificate:
          return 'Certificado HTTPS inválido para $kApiBaseUrl';
        case DioExceptionType.badResponse:
          final status = e.response?.statusCode;
          if (status == 401 || status == 403) {
            return 'Email ou senha inválidos.';
          }
          return 'Servidor retornou erro $status: ${e.response?.data}';
        case DioExceptionType.cancel:
          return 'Login cancelado.';
      }
    }
    return 'Erro inesperado: $e';
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { _loading = true; _error = null; });
    try {
      await ref.read(authProvider.notifier).login(_emailCtrl.text.trim(), _passCtrl.text);
      // Auth state.error path: provider rethrows wrapped in AsyncValue.error.
      final auth = ref.read(authProvider);
      if (auth.hasError) {
        setState(() => _error = _humanizeLoginError(auth.error!));
      }
    } catch (e) {
      setState(() => _error = _humanizeLoginError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const BergaLogo(size: 80),
                  const SizedBox(height: 20),
                  const BergaLogo(size: 36, showWordmark: true),
                  const SizedBox(height: 8),
                  Text('Streaming privado e sem anúncios', style: Theme.of(context).textTheme.bodyMedium),
                  const SizedBox(height: 48),
                  TextFormField(
                    controller: _emailCtrl,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(hintText: 'Email', prefixIcon: Icon(Icons.email_outlined)),
                    validator: (v) => v == null || !v.contains('@') ? 'Email inválido' : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _passCtrl,
                    obscureText: true,
                    decoration: const InputDecoration(hintText: 'Senha', prefixIcon: Icon(Icons.lock_outline)),
                    validator: (v) => v == null || v.length < 6 ? 'Senha muito curta' : null,
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.error.withOpacity(0.12),
                        border: Border.all(color: AppColors.error.withOpacity(0.5)),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _error!,
                        style: const TextStyle(color: AppColors.error, fontSize: 13),
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _loading ? null : _submit,
                      child: _loading
                          ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Text('Entrar'),
                    ),
                  ),
                  // Diagnostic footer: which API the app is configured to talk
                  // to.  Tappable to copy — when login fails because the APK
                  // was built without --dart-define=API_URL, this is how the
                  // user discovers it's pointing at localhost.
                  const SizedBox(height: 24),
                  InkWell(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: kApiBaseUrl));
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Copiado: $kApiBaseUrl'),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                      child: Text(
                        'API: $kApiBaseUrl',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 11,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: _testing ? null : _testConnection,
                    icon: _testing
                        ? const SizedBox(
                            width: 14, height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.network_check, size: 16),
                    label: const Text('Testar conexão com o servidor'),
                  ),
                  if (_diag != null) ...[
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        border: Border.all(color: AppColors.surfaceVariant),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: SelectableText(
                        _diag!,
                        style: const TextStyle(
                          fontSize: 10,
                          fontFamily: 'monospace',
                          color: AppColors.textSecondary,
                        ),
                      ),
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
