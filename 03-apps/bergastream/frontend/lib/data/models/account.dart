/// Conta de uma pessoa (`/api/admin/users` e `/api/auth/account`).
class Account {
  const Account({
    required this.id,
    required this.username,
    required this.name,
    this.email,
    this.isAdmin = false,
    this.disabled = false,
    this.linked = false,
    this.managedByAuthentik = false,
    this.adminManagedByAuthentik = false,
    this.hasPassword = false,
    this.lastLoginAt,
    this.sessions = 0,
    this.canChangePassword = false,
    this.accountUrl,
    this.mailEnabled = false,
    this.oidcEnabled = false,
  });

  factory Account.fromJson(Map<String, dynamic> json) => Account(
    id: json['id'] as String,
    username: json['username'] as String,
    name: json['name'] as String,
    email: json['email'] as String?,
    isAdmin: json['is_admin'] == true,
    disabled: json['disabled'] == true,
    linked: json['linked'] == true,
    managedByAuthentik: json['managed_by_authentik'] == true,
    adminManagedByAuthentik: json['admin_managed_by_authentik'] == true,
    hasPassword: json['has_password'] == true,
    lastLoginAt: DateTime.tryParse('${json['last_login_at']}')?.toLocal(),
    sessions: json['sessions'] as int? ?? 0,
    canChangePassword: json['can_change_password'] == true,
    accountUrl: json['account_url'] as String?,
    mailEnabled: json['mail_enabled'] == true,
    oidcEnabled: json['oidc_enabled'] == true,
  );

  final String id;
  final String username;
  final String name;
  final String? email;
  final bool isAdmin;
  final bool disabled;

  /// Já entrou pelo Authentik (a conta está presa à pessoa de lá).
  final bool linked;

  /// Usuário, nome, e-mail e senha vêm do Authentik (só leitura aqui).
  final bool managedByAuthentik;

  /// Quem é admin vem do grupo do Authentik.
  final bool adminManagedByAuthentik;
  final bool hasPassword;

  /// Último login pelo Authentik.
  final DateTime? lastLoginAt;

  /// Aparelhos conectados (sessões abertas).
  final int sessions;

  // Só em "minha conta":
  final bool canChangePassword;

  /// Página "Minha conta" do Authentik.
  final String? accountUrl;
  final bool mailEnabled;

  /// Login pelo Authentik ligado no servidor.
  final bool oidcEnabled;

  /// Ainda não entrou pelo Authentik, mas o servidor usa: usuário e e-mail
  /// daqui é que vão ligar as contas no 1º login.
  bool get linkPending => oidcEnabled && !linked;
}

/// Página de usuários do admin.
class UsersPage {
  const UsersPage({
    required this.users,
    this.mailEnabled = false,
    this.oidcEnabled = false,
    this.passwordLoginEnabled = true,
    this.authentikAdminUrl,
  });

  factory UsersPage.fromJson(Map<String, dynamic> json) => UsersPage(
    users: [
      for (final u in json['users'] as List<dynamic>)
        Account.fromJson(u as Map<String, dynamic>),
    ],
    mailEnabled: json['mail_enabled'] == true,
    oidcEnabled: json['oidc_enabled'] == true,
    passwordLoginEnabled: json['password_login_enabled'] != false,
    authentikAdminUrl: json['authentik_admin_url'] as String?,
  );

  final List<Account> users;
  final bool mailEnabled;
  final bool oidcEnabled;
  final bool passwordLoginEnabled;
  final String? authentikAdminUrl;
}

/// Resultado de "redefinir senha" pelo admin.
class PasswordReset {
  const PasswordReset({this.password, this.sent = false});

  /// Senha temporária (para o admin passar à pessoa).
  final String? password;

  /// Aviso (ou link) enviado por e-mail.
  final bool sent;
}
