import 'package:bergastream/features/update/app_release.dart';
import 'package:bergastream/features/update/update_service.dart';

AppRelease release(String version, {Map<String, String>? assets}) => AppRelease(
  version: AppVersion.tryParse(version)!,
  tag: 'bergastream-v$version',
  pageUrl: 'https://github.com/x/releases/tag/bergastream-v$version',
  notes: 'Novidades da $version',
  assets:
      assets ??
      {
        AppRelease.androidAsset: 'https://dl/android.apk',
        AppRelease.linuxAsset: 'https://dl/linux.tar.gz',
        AppRelease.windowsAsset: 'https://dl/windows.zip',
      },
);

class FakeUpdateRepository implements UpdateRepository {
  FakeUpdateRepository({this.current = '0.1.0', this.published, this.fail});

  final String current;
  AppRelease? published;
  Object? fail;
  int latestCalls = 0;
  final downloads = <(String url, String path)>[];

  @override
  Future<AppVersion> currentVersion() async => AppVersion.tryParse(current)!;

  @override
  Future<AppRelease?> latest() async {
    latestCalls++;
    if (fail case final error?) throw error;
    return published;
  }

  @override
  Future<void> download(
    String url,
    String path, {
    void Function(double progress)? onProgress,
  }) async {
    downloads.add((url, path));
    onProgress?.call(0.5);
    onProgress?.call(1);
  }
}

class FakeUpdateLauncher implements UpdateLauncher {
  final opened = <String>[];
  final pages = <String>[];

  @override
  Future<String> folderFor(UpdateTarget target) async =>
      target.installsDirectly ? '/tmp/cache' : '/home/u/Downloads';

  @override
  Future<bool> open(String path) async {
    opened.add(path);
    return true;
  }

  @override
  Future<bool> openPage(String url) async {
    pages.add(url);
    return true;
  }
}
