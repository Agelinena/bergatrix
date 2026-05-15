class AppUser {
  final String id;
  final String username;
  final String email;
  final String? avatarUrl;
  final bool isAdmin;
  final bool isActive;

  const AppUser({
    required this.id,
    required this.username,
    required this.email,
    this.avatarUrl,
    this.isAdmin = false,
    this.isActive = true,
  });

  factory AppUser.fromJson(Map<String, dynamic> json) => AppUser(
    id: json['id'] as String,
    username: json['username'] as String,
    email: json['email'] as String,
    avatarUrl: json['avatar_url'] as String?,
    isAdmin: json['is_admin'] as bool? ?? false,
    isActive: json['is_active'] as bool? ?? true,
  );

  String get initials => username.isNotEmpty ? username[0].toUpperCase() : '?';
}
