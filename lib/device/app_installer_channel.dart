import 'package:flutter/services.dart';

import 'package:superxd/domain/app_update.dart';

// 系统安装器的原生实现：通道 superxd/app_update，见 AppUpdateInstaller.kt。只接受缓存 app_update 文件夹里的 .apk。
class ChannelAppInstaller implements AppInstaller {
  static const _channel = MethodChannel('superxd/app_update');

  @override
  Future<bool> canInstall() async => await _channel.invokeMethod<bool>('canInstall') ?? false;

  @override
  Future<void> openInstallSettings() => _channel.invokeMethod<void>('openInstallSettings');

  @override
  Future<AppPackageIdentity> inspect(String path) async {
    final result = await _channel.invokeMapMethod<String, Object?>('inspect', {'path': path});
    return switch (result) {
      {'samePackage': final bool samePackage, 'versionCode': final int versionCode, 'sameSigner': final bool sameSigner} =>
        AppPackageIdentity(samePackage: samePackage, versionCode: versionCode, sameSigner: sameSigner),
      _ => throw const AppUpdateException('安装包读不出来，请重试'),
    };
  }

  @override
  Future<void> install(String path) => _channel.invokeMethod<void>('install', {'path': path});
}
