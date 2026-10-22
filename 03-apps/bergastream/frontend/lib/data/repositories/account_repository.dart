import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_error.dart';
import '../api/api_dio.dart';
import '../models/account.dart';
import '../models/auth.dart';

/// Contas: "minha conta" e a gestão de pessoas do admin
/// (`backend/app/accounts/routes.py`).
abstract interface class AccountRepository {
  Future<Account> myAccount();

  /// Só os campos informados mudam; `email: ''` apaga o e-mail.
  Future<Account> updateMyAccount({
    String? username,
    String? name,
    String? email,
  });

  /// Troca a própria senha; as outras sessões caem e este aparelho recebe
  /// tokens novos.
  Future<TokenResponse> changeMyPassword({
    required String current,
    required String next,
  });

  Future<UsersPage> users();
  Future<Account> createUser({
    required String username,
    String? name,
    String? email,
    bool isAdmin = false,
    bool invite = true,
  });
  Future<Account> updateUser(
    String id, {
    String? username,
    String? name,
    String? email,
    bool? isAdmin,
    bool? disabled,
    bool notify = true,
  });

  /// [link]: e-mail com o link de criar senha; senão, senha temporária.
  Future<PasswordReset> resetPassword(
    String id, {
    required bool link,
    bool notify = true,
  });
  Future<void> revokeSessions(String id);
  Future<Account> unlink(String id);
  Future<void> sendNotice(
    String id, {
    required String subject,
    required String message,
  });

  /// E-mail de teste para o próprio admin.
  Future<void> testMail();
}

class HttpAccountRepository implements AccountRepository {
  HttpAccountRepository(this._dio);

  final Dio _dio;

  Future<T> _call<T>(Future<T> Function() run) async {
    try {
      return await run();
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }

  Future<Map<String, dynamic>> _json(
    String method,
    String path, [
    Object? data,
  ]) => _call(() async {
    final response = await _dio.request<Map<String, dynamic>>(
      path,
      data: data,
      options: Options(method: method),
    );
    return response.data ?? const {};
  });

  static Map<String, dynamic> _fields(Map<String, Object?> all) => {
    for (final MapEntry(:key, :value) in all.entries) key: ?value,
  };

  @override
  Future<Account> myAccount() async =>
      Account.fromJson(await _json('GET', '/api/auth/account'));

  @override
  Future<Account> updateMyAccount({
    String? username,
    String? name,
    String? email,
  }) async => Account.fromJson(
    await _json(
      'PATCH',
      '/api/auth/account',
      _fields({'username': username, 'name': name, 'email': email}),
    ),
  );

  @override
  Future<TokenResponse> changeMyPassword({
    required String current,
    required String next,
  }) async => TokenResponse.fromJson(
    await _json('POST', '/api/auth/account/password', {
      'current_password': current,
      'new_password': next,
    }),
  );

  @override
  Future<UsersPage> users() async =>
      UsersPage.fromJson(await _json('GET', '/api/admin/users'));

  @override
  Future<Account> createUser({
    required String username,
    String? name,
    String? email,
    bool isAdmin = false,
    bool invite = true,
  }) async => Account.fromJson(
    await _json(
      'POST',
      '/api/admin/users',
      _fields({
        'username': username,
        'name': name,
        'email': email,
        'is_admin': isAdmin,
        'invite': invite,
      }),
    ),
  );

  @override
  Future<Account> updateUser(
    String id, {
    String? username,
    String? name,
    String? email,
    bool? isAdmin,
    bool? disabled,
    bool notify = true,
  }) async => Account.fromJson(
    await _json(
      'PATCH',
      '/api/admin/users/$id',
      _fields({
        'username': username,
        'name': name,
        'email': email,
        'is_admin': isAdmin,
        'disabled': disabled,
        'notify': notify,
      }),
    ),
  );

  @override
  Future<PasswordReset> resetPassword(
    String id, {
    required bool link,
    bool notify = true,
  }) async {
    final data = await _json('POST', '/api/admin/users/$id/password', {
      'mode': link ? 'link' : 'temporary',
      'notify': notify,
    });
    return PasswordReset(
      password: data['password'] as String?,
      sent: data['sent'] == true,
    );
  }

  @override
  Future<void> revokeSessions(String id) =>
      _json('POST', '/api/admin/users/$id/sessions/revoke');

  @override
  Future<Account> unlink(String id) async =>
      Account.fromJson(await _json('POST', '/api/admin/users/$id/unlink'));

  @override
  Future<void> sendNotice(
    String id, {
    required String subject,
    required String message,
  }) => _json('POST', '/api/admin/users/$id/notice', {
    'subject': subject,
    'message': message,
  });

  @override
  Future<void> testMail() => _json('POST', '/api/admin/mail/test');
}

final accountRepositoryProvider = Provider<AccountRepository>(
  (ref) => HttpAccountRepository(ref.watch(apiDioProvider)),
);

/// Contas em memória (testes): mesmas regras principais do servidor.
class FakeAccountRepository implements AccountRepository {
  FakeAccountRepository({
    List<Account>? accounts,
    this.meId = 'u1',
    this.mailEnabled = true,
    this.oidcEnabled = false,
    this.passwordLoginEnabled = true,
  }) : accounts =
           accounts ??
           [
             const Account(
               id: 'u1',
               username: 'demo',
               name: 'Demo',
               email: 'demo@example.com',
               isAdmin: true,
               hasPassword: true,
             ),
           ];

  final List<Account> accounts;
  String meId;
  bool mailEnabled;
  bool oidcEnabled;
  bool passwordLoginEnabled;
  final notices = <(String id, String subject)>[];
  final resets = <(String id, bool link)>[];
  final revoked = <String>[];

  Account _get(String id) => accounts.firstWhere((a) => a.id == id);

  void _put(Account a) =>
      accounts[accounts.indexWhere((x) => x.id == a.id)] = a;

  static const _managed = ApiException(
    ApiErrorKind.requisicao,
    statusCode: 409,
    detail: 'Usuário, nome e e-mail desta conta vêm do Authentik.',
  );

  Account _with(
    Account a, {
    String? username,
    String? name,
    String? email,
    bool? isAdmin,
    bool? disabled,
    bool? linked,
  }) => Account(
    id: a.id,
    username: username ?? a.username,
    name: name ?? a.name,
    email: email == null ? a.email : (email.isEmpty ? null : email),
    isAdmin: isAdmin ?? a.isAdmin,
    disabled: disabled ?? a.disabled,
    linked: linked ?? a.linked,
    managedByAuthentik: oidcEnabled && (linked ?? a.linked),
    adminManagedByAuthentik: a.adminManagedByAuthentik,
    hasPassword: a.hasPassword,
    sessions: a.sessions,
  );

  @override
  Future<Account> myAccount() async {
    final a = _get(meId);
    return Account(
      id: a.id,
      username: a.username,
      name: a.name,
      email: a.email,
      isAdmin: a.isAdmin,
      linked: a.linked,
      managedByAuthentik: a.managedByAuthentik,
      hasPassword: a.hasPassword,
      canChangePassword: passwordLoginEnabled && !a.managedByAuthentik,
      accountUrl: a.managedByAuthentik
          ? 'https://authentik.example.com/if/user/#/settings'
          : null,
      mailEnabled: mailEnabled,
      oidcEnabled: oidcEnabled,
    );
  }

  @override
  Future<Account> updateMyAccount({
    String? username,
    String? name,
    String? email,
  }) async {
    final a = _get(meId);
    if (a.managedByAuthentik) throw _managed;
    _put(_with(a, username: username, name: name, email: email));
    return myAccount();
  }

  @override
  Future<TokenResponse> changeMyPassword({
    required String current,
    required String next,
  }) async {
    final a = _get(meId);
    return TokenResponse(
      accessToken: 'novo-access',
      refreshToken: 'novo-refresh',
      expiresIn: 900,
      user: AuthUser(id: a.id, username: a.username, name: a.name),
    );
  }

  @override
  Future<UsersPage> users() async => UsersPage(
    users: List.of(accounts),
    mailEnabled: mailEnabled,
    oidcEnabled: oidcEnabled,
    passwordLoginEnabled: passwordLoginEnabled,
    authentikAdminUrl: oidcEnabled
        ? 'https://authentik.example.com/if/admin/#/identity/users'
        : null,
  );

  @override
  Future<Account> createUser({
    required String username,
    String? name,
    String? email,
    bool isAdmin = false,
    bool invite = true,
  }) async {
    if (accounts.any((a) => a.username == username)) {
      throw const ApiException(
        ApiErrorKind.requisicao,
        statusCode: 409,
        detail: 'Já existe uma conta com este usuário.',
      );
    }
    final a = Account(
      id: 'u${accounts.length + 1}',
      username: username,
      name: name ?? username,
      email: email,
      isAdmin: isAdmin,
    );
    accounts.add(a);
    return a;
  }

  @override
  Future<Account> updateUser(
    String id, {
    String? username,
    String? name,
    String? email,
    bool? isAdmin,
    bool? disabled,
    bool notify = true,
  }) async {
    final a = _get(id);
    final identity =
        (username != null && username != a.username) ||
        (name != null && name != a.name) ||
        (email != null && email != (a.email ?? ''));
    if (identity && a.managedByAuthentik) throw _managed;
    final next = _with(
      a,
      username: username,
      name: name,
      email: email,
      isAdmin: isAdmin,
      disabled: disabled,
    );
    _put(next);
    return next;
  }

  @override
  Future<PasswordReset> resetPassword(
    String id, {
    required bool link,
    bool notify = true,
  }) async {
    resets.add((id, link));
    return link
        ? const PasswordReset(sent: true)
        : const PasswordReset(password: 'Temp4Senha7x', sent: true);
  }

  @override
  Future<void> revokeSessions(String id) async => revoked.add(id);

  @override
  Future<Account> unlink(String id) async {
    final a = _with(_get(id), linked: false);
    _put(a);
    return a;
  }

  @override
  Future<void> sendNotice(
    String id, {
    required String subject,
    required String message,
  }) async => notices.add((id, subject));

  @override
  Future<void> testMail() async => notices.add((meId, 'teste'));
}
