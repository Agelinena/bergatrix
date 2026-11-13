// Modelos da API do Doberga (backend/app/*/routes.py), lidos à mão do JSON.

typedef Json = Map<String, dynamic>;

DateTime? _date(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toLocal() : null;

class User {
  const User({
    required this.id,
    required this.username,
    required this.name,
    required this.isAdmin,
    this.email,
  });

  final String id;
  final String username;
  final String name;
  final String? email;
  final bool isAdmin;

  factory User.fromJson(Json j) => User(
    id: j['id'] as String,
    username: j['username'] as String,
    name: j['name'] as String,
    email: j['email'] as String?,
    isAdmin: j['is_admin'] as bool? ?? false,
  );
}

class Tokens {
  const Tokens({required this.access, required this.refresh});

  final String access;
  final String refresh;
}

class AuthConfig {
  const AuthConfig({required this.oidcEnabled, required this.accountUrl});

  final bool oidcEnabled;
  final String accountUrl;

  factory AuthConfig.fromJson(Json j) => AuthConfig(
    oidcEnabled: j['oidc_enabled'] as bool? ?? false,
    accountUrl: j['account_url'] as String? ?? '',
  );
}

// ── Espaços ───────────────────────────────────────────────────────────

class Member {
  const Member({
    required this.userId,
    required this.name,
    required this.username,
    required this.role,
  });

  final String userId;
  final String name;
  final String username;
  final String role;

  bool get isOwner => role == 'owner';

  factory Member.fromJson(Json j) => Member(
    userId: j['user_id'] as String,
    name: j['name'] as String,
    username: j['username'] as String,
    role: j['role'] as String,
  );

  Json toJson() => {
    'user_id': userId,
    'name': name,
    'username': username,
    'role': role,
  };
}

/// Espaço pessoal ou grupo. Todo dado dos módulos pertence a um espaço.
class Space {
  const Space({
    required this.id,
    required this.kind,
    required this.name,
    required this.role,
    required this.members,
    this.color,
    this.icon,
  });

  final String id;
  final String kind;
  final String name;
  final String? color;
  final String? icon;

  /// Papel de quem está usando o app.
  final String role;
  final List<Member> members;

  bool get isPersonal => kind == 'personal';
  bool get isOwner => role == 'owner';

  factory Space.fromJson(Json j) => Space(
    id: j['id'] as String,
    kind: j['kind'] as String,
    name: j['name'] as String,
    color: j['color'] as String?,
    icon: j['icon'] as String?,
    role: j['role'] as String,
    members: [
      for (final m in (j['members'] as List? ?? const []))
        Member.fromJson(m as Json),
    ],
  );

  Json toJson() => {
    'id': id,
    'kind': kind,
    'name': name,
    'color': color,
    'icon': icon,
    'role': role,
    'members': [for (final m in members) m.toJson()],
  };
}

class InvitePreview {
  const InvitePreview({
    required this.spaceId,
    required this.spaceName,
    required this.members,
    required this.alreadyMember,
    this.inviter,
  });

  final String spaceId;
  final String spaceName;
  final String? inviter;
  final int members;
  final bool alreadyMember;

  factory InvitePreview.fromJson(Json j) => InvitePreview(
    spaceId: j['space_id'] as String,
    spaceName: j['space_name'] as String,
    inviter: j['inviter'] as String?,
    members: (j['members'] as num?)?.toInt() ?? 0,
    alreadyMember: j['already_member'] as bool? ?? false,
  );
}

class CreatedInvite {
  const CreatedInvite({required this.url, required this.expiresAt});

  final String url;
  final DateTime? expiresAt;

  factory CreatedInvite.fromJson(Json j) => CreatedInvite(
    url: j['url'] as String,
    expiresAt: _date(j['expires_at']),
  );
}

// ── Preferências ──────────────────────────────────────────────────────

/// Abas (ids iguais aos do servidor, app/prefs/routes.py).
enum TabId {
  today('Hoje'),
  shopping('Compras'),
  recurring('Recorrentes'),
  calendar('Calendário'),
  notes('Notas');

  const TabId(this.label);

  final String label;

  static TabId? parse(String value) {
    for (final t in TabId.values) {
      if (t.name == value) return t;
    }
    return null;
  }
}

class TabPref {
  const TabPref({required this.id, required this.enabled, required this.available});

  final TabId id;
  final bool enabled;
  final bool available;

  Json toJson() => {'id': id.name, 'enabled': enabled};
}

class Prefs {
  const Prefs({
    required this.tabs,
    this.theme = 'system',
    this.defaultSpaces = const {},
    this.notifyHour = 9,
    this.weekStart = 'monday',
  });

  static const fallback = Prefs(tabs: [
    TabPref(id: TabId.today, enabled: true, available: true),
  ]);

  final List<TabPref> tabs;
  final String theme;
  final Map<String, String> defaultSpaces;
  final int notifyHour;
  final String weekStart;

  List<TabId> get visibleTabs => [
    for (final t in tabs)
      if (t.enabled && t.available) t.id,
  ];

  factory Prefs.fromJson(Json j) => Prefs(
    tabs: [
      for (final t in (j['tabs'] as List? ?? const []))
        if (TabId.parse((t as Json)['id'] as String) case final id?)
          TabPref(
            id: id,
            enabled: t['enabled'] as bool? ?? false,
            available: t['available'] as bool? ?? true,
          ),
    ],
    theme: j['theme'] as String? ?? 'system',
    defaultSpaces: {
      for (final e in ((j['default_spaces'] as Map?) ?? const {}).entries)
        e.key as String: e.value as String,
    },
    notifyHour: (j['notify_hour'] as num?)?.toInt() ?? 9,
    weekStart: j['week_start'] as String? ?? 'monday',
  );
}

// ── Admin ─────────────────────────────────────────────────────────────

class AdminUser {
  const AdminUser({
    required this.id,
    required this.username,
    required this.name,
    required this.isAdmin,
    required this.disabled,
    required this.spaces,
    required this.sessions,
    this.email,
    this.lastLoginAt,
  });

  final String id;
  final String username;
  final String name;
  final String? email;
  final bool isAdmin;
  final bool disabled;
  final int spaces;
  final int sessions;
  final DateTime? lastLoginAt;

  factory AdminUser.fromJson(Json j) => AdminUser(
    id: j['id'] as String,
    username: j['username'] as String,
    name: j['name'] as String,
    email: j['email'] as String?,
    isAdmin: j['is_admin'] as bool? ?? false,
    disabled: j['disabled'] as bool? ?? false,
    spaces: (j['spaces'] as num?)?.toInt() ?? 0,
    sessions: (j['sessions'] as num?)?.toInt() ?? 0,
    lastLoginAt: _date(j['last_login_at']),
  );
}
