class AppUser {
  final String id;
  final String username;
  final String email;
  final String? avatarUrl;

  const AppUser({
    required this.id,
    required this.username,
    required this.email,
    this.avatarUrl,
  });

  factory AppUser.fromJson(Map<String, dynamic> json) => AppUser(
    id: json['id'] as String,
    username: json['username'] as String,
    email: json['email'] as String,
    avatarUrl: json['avatar_url'] as String?,
  );

  String get initials => username.isNotEmpty ? username[0].toUpperCase() : '?';
}
