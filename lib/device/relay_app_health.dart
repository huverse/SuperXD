import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:superxd/domain/app_health.dart';
import 'package:superxd/domain/campus_http.dart';
import 'package:superxd/domain/campus_log.dart';

// 健康回报与意见的自建中转实现（人工决策见 domain/app_health.dart）：POST /v1/app/health（11-17 起另带启动档 launch 与慢帧档 frames，只有档位，没有的不带）与 /v1/app/feedback，免签名、不带任何标识，
// 经共用请求内核 CampusHttp 发（请求记录在内核里记，模块 app_health），单次 15 秒超时、回复上限 4KB（成功是 204 空回复）、不自动重试。
class RelayAppHealthClient implements AppHealthClient {
  RelayAppHealthClient(this.baseUrl, {http.Client? client, this.timeout = const Duration(seconds: 15)}) : _http = CampusHttp('app_health', client: client);
  final String baseUrl;
  final Duration timeout;
  final CampusHttp _http;
  static const limit = 4 * 1024;

  Future<void> _post(String path, Map<String, Object?> body) async {
    final http.Response response;
    try {
      response = await _http.send('POST', Uri.parse('$baseUrl$path'), timeout: timeout, limit: limit, headers: const {'content-type': 'application/json'}, body: jsonEncode(body));
    } catch (error, stack) {
      campusLog('[AppHealth] action=post path=$path errorType=${error.runtimeType}\n$stack');
      throw const AppHealthException('连不上服务器');
    }
    if (response.statusCode == 204) return;
    campusLog('[AppHealth] action=post path=$path status=${response.statusCode}');
    if (response.statusCode == 429) throw const AppHealthException('提交太频繁，请稍后再试');
    throw AppHealthException('服务器回了 ${response.statusCode}', rejected: response.statusCode >= 400 && response.statusCode < 500);
  }

  @override
  Future<void> report({required String channel, required String platform, required HealthDay day}) =>
      _post('/v1/app/health', {'channel': channel, 'platform': platform, 'versionCode': day.versionCode, 'day': day.day, 'fatal': day.fatal, 'launch': ?day.launchTier, 'frames': ?day.frameTier});

  @override
  Future<void> feedback({required String channel, required String platform, required int versionCode, required bool good, required String text}) =>
      _post('/v1/app/feedback', {'channel': channel, 'platform': platform, 'versionCode': versionCode, 'good': good, 'text': text});
}
