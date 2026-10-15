import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import 'package:http/http.dart' as http;

import 'package:superxd/domain/app_update.dart';
import 'package:superxd/domain/campus_log.dart';

// 清单很小（服务端按 64KB 封顶），响应超过就当异常，不往下读。
const appReleaseResponseMaxBytes = 64 * 1024;

// 安装包按正在运行的架构取：与发布附件的三种分包一致；认不出的架构（桌面测试等）不检查更新。
String? appAbiName(Abi abi) => switch (abi) {
  Abi.androidArm64 => 'arm64-v8a',
  Abi.androidArm => 'armeabi-v7a',
  Abi.androidX64 => 'x86_64',
  _ => null,
};

// 版本清单的自建中转实现：GET /v1/app/releases/<渠道>?abi=，免签名，单次 15 秒超时、不自动重试。
class RelayReleaseFeed implements AppReleaseFeed {
  RelayReleaseFeed(this.baseUrl, {required this.channel, required this.abi, http.Client? client, this.timeout = const Duration(seconds: 15)}) : _client = client ?? http.Client();
  final String baseUrl;
  final String channel;
  final String abi;
  final Duration timeout;
  final http.Client _client;

  @override
  Future<AppRelease?> latest() async {
    final uri = Uri.parse('$baseUrl/v1/app/releases/$channel').replace(queryParameters: {'abi': abi});
    final int status;
    final List<int> body;
    try {
      final response = await _client.send(http.Request('GET', uri)).timeout(timeout);
      status = response.statusCode;
      body = await _read(response.stream).timeout(timeout);
    } on TimeoutException catch (error, stack) {
      campusLog('[AppUpdate] action=feed errorType=${error.runtimeType}\n$stack');
      throw const AppUpdateException('连不上更新服务器，请稍后再试');
    } on AppUpdateException {
      rethrow;
    } catch (error, stack) {
      campusLog('[AppUpdate] action=feed errorType=${error.runtimeType}\n$stack');
      throw const AppUpdateException('连不上更新服务器，请检查网络后再试');
    }
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(body));
    } on FormatException catch (error, stack) {
      campusLog('[AppUpdate] action=feed status=$status errorType=${error.runtimeType}\n$stack');
      throw const AppUpdateException('更新服务器暂时不可用，请稍后再试');
    }
    if (status == 404 && json is Map && json['code'] == 'RELEASE_NOT_FOUND') return null;
    if (status == 429 || status == 503) throw const AppUpdateException('检查更新的人太多，请稍后再试');
    if (status != 200) {
      campusLog('[AppUpdate] action=feed status=$status code=${json is Map ? json['code'] : null}');
      throw const AppUpdateException('更新服务器暂时不可用，请稍后再试');
    }
    try {
      return parseAppRelease(json, baseUrl);
    } on FormatException catch (error, stack) {
      campusLog('[AppUpdate] action=feed errorType=${error.runtimeType} message=${error.message}\n$stack');
      throw const AppUpdateException('更新信息格式不对，请稍后再试');
    }
  }

  Future<List<int>> _read(Stream<List<int>> stream) async {
    final bytes = <int>[];
    await for (final chunk in stream) {
      bytes.addAll(chunk);
      if (bytes.length > appReleaseResponseMaxBytes) throw const AppUpdateException('更新服务器暂时不可用，请稍后再试');
    }
    return bytes;
  }
}

// 清单是外部输入：逐项校验，不合格抛 FormatException。安装包地址只认本服务的下载路径，拼在中转地址后面。
AppRelease parseAppRelease(Object? json, String baseUrl) {
  if (json is! Map) throw const FormatException('清单不是对象');
  int integer(String key, int min) => switch (json[key]) {
    final int value when value >= min => value,
    _ => throw FormatException('$key 不合法'),
  };
  String text(String key, int maxLength) => switch (json[key]) {
    final String value when value.length <= maxLength => value,
    _ => throw FormatException('$key 不合法'),
  };
  final publishedAt = DateTime.tryParse(text('publishedAt', 64));
  final releasePage = Uri.tryParse(text('releasePage', 500));
  if (publishedAt == null) throw const FormatException('publishedAt 不合法');
  if (releasePage == null || !releasePage.isScheme('https') || releasePage.host.isEmpty) throw const FormatException('releasePage 不合法');
  final versionName = text('versionName', 64);
  if (versionName.isEmpty) throw const FormatException('versionName 为空');
  final apk = switch (json['apk']) {
    null => null,
    {'url': final String url, 'size': final int size, 'sha256': final String sha256}
        when RegExp(r'^/v1/app/files/[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.apk$').hasMatch(url) && size > 0 && RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256) =>
      AppReleaseApk(url: Uri.parse('$baseUrl$url'), size: size, sha256: sha256),
    _ => throw const FormatException('apk 不合法'),
  };
  return AppRelease(
    versionCode: integer('versionCode', 1),
    versionName: versionName,
    publishedAt: publishedAt.toUtc(),
    minSupportedVersionCode: integer('minSupportedVersionCode', 0),
    notes: text('notes', 4000),
    releasePage: releasePage,
    apk: apk,
  );
}
