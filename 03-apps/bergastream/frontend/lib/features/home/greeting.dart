/// Saudação por horário: 5h–11h59 "Bom dia", 12h–17h59 "Boa tarde",
/// demais "Boa noite".
String greetingFor(DateTime now) {
  final hour = now.hour;
  if (hour >= 5 && hour < 12) return 'Bom dia';
  if (hour >= 12 && hour < 18) return 'Boa tarde';
  return 'Boa noite';
}
