import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Resultado de um download de arquivo.
class FetchResult {
  const FetchResult({required this.bytes, this.expectedBytes, this.format});

  final int bytes;

  /// `Content-Length` informado pelo servidor (para validar o arquivo).
  final int? expectedBytes;

  /// Extensão do áudio informada pelo servidor (`X-Track-Format`).
  final String? format;
}

/// Baixa um arquivo para [path]. Lança em erro de rede ou HTTP.
abstract interface class FileFetcher {
  Future<FetchResult> fetch(
    Uri url,
    String path, {
    String? label,
    void Function(double progress)? onProgress,
  });
}

/// Download direto com o `dio` (desktop e reserva).
class DioFileFetcher implements FileFetcher {
  DioFileFetcher([Dio? dio]) : _dio = dio ?? Dio();

  final Dio _dio;

  @override
  Future<FetchResult> fetch(
    Uri url,
    String path, {
    String? label,
    void Function(double progress)? onProgress,
  }) async {
    final response = await _dio.downloadUri(
      url,
      path,
      onReceiveProgress: (received, total) {
        if (total > 0) onProgress?.call(received / total);
      },
    );
    return FetchResult(
      bytes: await File(path).length(),
      expectedBytes: int.tryParse(
        response.headers.value(Headers.contentLengthHeader) ?? '',
      ),
      format: response.headers.value('x-track-format'),
    );
  }
}

/// Android: `background_downloader`, que continua com o app em segundo
/// plano e mostra a notificação de progresso (Seção 8.5).
class BackgroundFileFetcher implements FileFetcher {
  @override
  Future<FetchResult> fetch(
    Uri url,
    String path, {
    String? label,
    void Function(double progress)? onProgress,
  }) async {
    final file = File(path);
    final task = DownloadTask(
      url: url.toString(),
      filename: file.uri.pathSegments.last,
      directory: file.parent.path,
      baseDirectory: BaseDirectory.root,
      updates: Updates.statusAndProgress,
      displayName: label ?? '',
      retries: 0,
    );
    final update = await FileDownloader().download(
      task,
      onProgress: (p) {
        if (p >= 0) onProgress?.call(p);
      },
    );
    if (update.status != TaskStatus.complete) {
      throw HttpException(
        'Download ${update.status.name} (${update.responseStatusCode})',
        uri: url,
      );
    }
    final headers = {
      for (final e in (update.responseHeaders ?? const {}).entries)
        e.key.toLowerCase(): e.value,
    };
    return FetchResult(
      bytes: await file.length(),
      expectedBytes: int.tryParse(headers['content-length'] ?? ''),
      format: headers['x-track-format'],
    );
  }
}

/// Configura a notificação de progresso dos downloads (Android).
void configureDownloadNotifications() {
  if (kIsWeb || !Platform.isAndroid) return;
  FileDownloader().configureNotification(
    running: const TaskNotification('Baixando', '{displayName}'),
    error: const TaskNotification('Falha no download', '{displayName}'),
    progressBar: true,
  );
}

final fileFetcherProvider = Provider<FileFetcher>((ref) {
  if (!kIsWeb && Platform.isAndroid) return BackgroundFileFetcher();
  return DioFileFetcher();
});
