import 'dart:typed_data';

import 'files_io.dart' if (dart.library.js_interop) 'files_web.dart' as platform;

/// Guarda um arquivo gerado pelo app (ex.: o OPML exportado). Web: baixa;
/// Android: abre o compartilhar; computador: salva em Downloads. Devolve a
/// frase para mostrar à pessoa.
Future<String> saveFile(String name, Uint8List bytes, String mimeType) =>
    platform.saveFile(name, bytes, mimeType);
