import 'package:flutter/material.dart';

/// Azul do ícone. Material 3 a partir dele, claro e escuro.
const brandBlue = Color(0xFF2155D6);

ThemeData buildTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: brandBlue,
    brightness: brightness,
  );
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    visualDensity: VisualDensity.standard,
    appBarTheme: AppBarTheme(
      centerTitle: false,
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
    ),
    listTileTheme: const ListTileThemeData(
      contentPadding: EdgeInsets.symmetric(horizontal: 16),
    ),
  );
}

ThemeMode themeModeOf(String value) => switch (value) {
  'light' => ThemeMode.light,
  'dark' => ThemeMode.dark,
  _ => ThemeMode.system,
};

/// Largura a partir da qual o app usa a barra lateral e o leitor centralizado.
const wideLayout = 840.0;

/// Largura máxima do texto no leitor (linhas longas cansam).
const readerWidth = 720.0;
