import 'session.dart';

/// Para onde redirecionar conforme a sessão (Seção 2.3). Nulo = fica.
///
/// - **Web:** sem sessão, só a tela de login abre.
/// - **App:** sem login pode usar o modo local; sessão expirada continua
///   no app.
String? accessRedirect({
  required SessionState session,
  required bool isWeb,
  required String location,
  required String loginRoute,
  required String homeRoute,
  Set<String> publicRoutes = const {},
}) {
  if (publicRoutes.contains(location)) return null;

  final canUseApp =
      session.isLoggedIn ||
      !isWeb &&
          (session.status == SessionStatus.sessaoExpirada || session.localMode);
  final onLogin = location == loginRoute;

  if (!canUseApp) return onLogin ? null : loginRoute;
  if (onLogin && session.isLoggedIn) return homeRoute;
  return null;
}
