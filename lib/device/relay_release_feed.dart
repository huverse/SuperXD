import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import 'package:http/http.dart' as http;

import 'package:superxd/domain/app_update.dart';
import 'package:superxd/domain/campus_http.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/device/signed_content.dart';

// 一次响应只有一个架构的信封加明文字段，更新说明最多 4000 字时也不到 30KB；超过 64KB 就当异常，不往下读。
// （中转上的清单文件带三个架构的信封，按 128KB 封顶，见 tool/release_manifest.dart。）
const appReleaseResponseMaxBytes = 64 * 1024;

// 安装包按正在运行的架构取：与发布附件的三种分包一致；认不出的架构（桌面测试等）不检查更新。
String? appAbiName(Abi abi) => switch (abi) {
  Abi.androidArm64 => 'arm64-v8a',
  Abi.androidArm => 'armeabi-v7a',
  Abi.androidX64 => 'x86_64',
  _ => null,
};

// 版本清单的自建中转实现：GET /v1/app/releases/<渠道>?abi=，请求免设备签名，单次 15 秒超时、不自动重试。
// 经共用请求内核 CampusHttp 发（超时管到读完响应体、到点中断连接，响应边读边限长，请求记录在内核里记，模块 app_update）。
// 只认清单里验签通过的载荷（人工决策见 device/signed_content.dart），没有签名或验不过按失败处理、不提示更新。
// packages 为假时不要安装包（iOS 不能在应用里安装，只看有没有新版本，下载去发布页）。
class RelayReleaseFeed implements AppReleaseFeed {
  RelayReleaseFeed(
    this.baseUrl, {
    required this.channel,
    required this.abi,
    this.packages = true,
    this.keys = trustedSigningKeys,
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
  }) : _http = CampusHttp('app_update', client: client);
  final String baseUrl;
  final String channel;
  final String abi;
  final bool packages;
  final List<TrustedSigningKey> keys;
  final Duration timeout;
  final CampusHttp _http;

  @override
  Future<AppRelease?> latest() async {
    final uri = Uri.parse('$baseUrl/v1/app/releases/$channel').replace(queryParameters: {'abi': abi});
    final http.Response response;
    try {
      response = await _http.send('GET', uri, timeout: timeout, limit: appReleaseResponseMaxBytes);
    } on TimeoutException catch (error, stack) {
      campusLog('[AppUpdate] action=feed errorType=${error.runtimeType}\n$stack');
      throw const AppUpdateException('连不上更新服务器，请稍后再试');
    } on CampusHttpTooLarge catch (error, stack) {
      campusLog('[AppUpdate] action=feed errorType=${error.runtimeType}\n$stack');
      throw const AppUpdateException('更新服务器暂时不可用，请稍后再试');
    } catch (error, stack) {
      campusLog('[AppUpdate] action=feed errorType=${error.runtimeType}\n$stack');
      throw const AppUpdateException('连不上更新服务器，请检查网络后再试');
    }
    final status = response.statusCode, body = response.bodyBytes;
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
      return await parseSignedAppRelease(json, baseUrl: baseUrl, channel: channel, abi: abi, packages: packages, keys: keys);
    } on SignedEnvelopeException catch (error, stack) {
      campusLog('[AppUpdate] action=feed errorType=${error.runtimeType} reason=${error.reason}\n$stack');
      throw const AppUpdateException('更新信息没通过校验，请稍后再试');
    } on FormatException catch (error, stack) {
      campusLog('[AppUpdate] action=feed errorType=${error.runtimeType} message=${error.message}\n$stack');
      throw const AppUpdateException('更新信息格式不对，请稍后再试');
    }
  }
}

// 中转的返回：明文字段（给旧客户端）一律不用，只取 envelope 验签，载荷交给 parseAppReleasePayload。
Future<AppRelease> parseSignedAppRelease(
  Object? response, {
  required String baseUrl,
  required String channel,
  required String abi,
  bool packages = true,
  List<TrustedSigningKey> keys = trustedSigningKeys,
}) async {
  if (response is! Map) throw const FormatException('清单不是对象');
  final payload = await openSignedEnvelope(response['envelope'], SignedContent.release, keys: keys);
  return parseAppReleasePayload(jsonDecode(utf8.decode(payload)), baseUrl: baseUrl, channel: channel, abi: abi, packages: packages);
}

// 验过签的载荷（tool/release_manifest.dart 按架构各签一份）仍是外部输入：逐项校验，不合格抛 FormatException。
// 渠道与架构必须是本机的，防止别的渠道、别的架构的清单被拿来重放；安装包只认本服务下载路径里的文件名，拼在中转地址后面。
AppRelease parseAppReleasePayload(Object? json, {required String baseUrl, required String channel, required String abi, bool packages = true}) {
  if (json is! Map) throw const FormatException('载荷不是对象');
  if (json['channel'] != channel || json['abi'] != abi) throw const FormatException('载荷的渠道或架构不是本机的');
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
    _ when !packages => null,
    null => null,
    {'file': final String file, 'size': final int size, 'sha256': final String sha256}
        when RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.apk$').hasMatch(file) && size > 0 && RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256) =>
      AppReleaseApk(url: Uri.parse('$baseUrl/v1/app/files/$file'), size: size, sha256: sha256),
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
