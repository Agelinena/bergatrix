import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

Future<String> saveFile(String name, Uint8List bytes, String mimeType) async {
  if (Platform.isAndroid || Platform.isIOS) {
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile.fromData(bytes, mimeType: mimeType, name: name)],
        fileNameOverrides: [name],
      ),
    );
    return 'Arquivo $name pronto';
  }
  final folder =
      await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
  final file = File('${folder.path}${Platform.pathSeparator}$name');
  await file.writeAsBytes(bytes);
  return 'Salvo em ${file.path}';
}
