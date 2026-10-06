import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';

// 代签凭据包的中转：上传密文换一个取件号，对方凭号取走，取走即删。
// 与私信共用同一个自建中转，只多一条路径；地址没配时面对面代签不可用，界面据此隐藏入口。
class ChaoxingPackHub {
  ChaoxingPackHub({
    required this.baseUrl,
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
  }) : _client = client ?? http.Client();

  final Uri? baseUrl;
  final Duration timeout;
  final http.Client _client;

  static const payloadLimit = 8192;

  bool get available => baseUrl != null;

  Future<String> submit(List<int> cipherText) async {
    final json = await _post('/v1/chaoxing/packs', jsonEncode({'data': _encode(cipherText)}));
    final id = '${json['id'] ?? ''}';
    if (!RegExp(r'^[A-Za-z0-9_-]{16}$').hasMatch(id)) {
      throw const ChaoxingFailure(ChaoxingFailureCode.invalidResponse, '中转服务返回了未知结果');
    }
    return id;
  }

  Future<Uint8List> pickup(String pickupId) async {
    final json = await _post('/v1/chaoxing/packs/$pickupId/pickup', '{}');
    final data = '${json['data'] ?? ''}';
    if (data.isEmpty) {
      throw const ChaoxingFailure(ChaoxingFailureCode.invalidResponse, '中转服务返回了未知结果');
    }
    try {
      return base64Url.decode(data.padRight((data.length + 3) ~/ 4 * 4, '='));
    } on FormatException {
      throw const ChaoxingFailure(ChaoxingFailureCode.invalidResponse, '中转服务返回了未知结果');
    }
  }

  static String _encode(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

  Future<Map<String, Object?>> _post(String path, String body) async {
    final base = baseUrl;
    if (base == null) {
      throw const ChaoxingFailure(ChaoxingFailureCode.unavailable, '还没有配置中转服务，面对面代签不可用');
    }
    final uri = base.replace(path: path);
    try {
      final response = await _client
          .post(uri, headers: {'content-type': 'application/json'}, body: body)
          .timeout(timeout);
      if (response.bodyBytes.length > payloadLimit) {
        throw const ChaoxingFailure(ChaoxingFailureCode.invalidResponse, '中转服务返回了未知结果');
      }
      final decoded = response.body.isEmpty ? null : jsonDecode(response.body);
      final json = decoded is Map ? decoded.cast<String, Object?>() : const <String, Object?>{};
      if (response.statusCode == 200) return json;
      throw _failure(response.statusCode, json);
    } on ChaoxingFailure {
      rethrow;
    } on TimeoutException catch (error, stack) {
      _log(path, 'timeout', error, stack);
      throw const ChaoxingFailure(ChaoxingFailureCode.timeout, '中转服务没有响应，请稍后重试');
    } on SocketException catch (error, stack) {
      _log(path, 'network', error, stack);
      throw const ChaoxingFailure(ChaoxingFailureCode.network, '连不上中转服务，请检查网络');
    } on http.ClientException catch (error, stack) {
      _log(path, 'network', error, stack);
      throw const ChaoxingFailure(ChaoxingFailureCode.network, '中转请求没有完成，请稍后重试');
    } on FormatException catch (error, stack) {
      _log(path, 'response', error, stack);
      throw const ChaoxingFailure(ChaoxingFailureCode.invalidResponse, '中转服务返回了未知结果');
    }
  }

  ChaoxingFailure _failure(int status, Map<String, Object?> json) {
    final code = '${json['code'] ?? ''}';
    final retryAfter = json['retryAfter'];
    return switch (code) {
      'PACK_NOT_FOUND' => const ChaoxingFailure(ChaoxingFailureCode.packNotFound, '这个代签码已经用过或过期了，请让对方重新生成'),
      'RATE_LIMITED' => ChaoxingFailure(
        ChaoxingFailureCode.rateLimited,
        '操作太频繁了，请稍后再试',
        retryAfter: retryAfter is num ? Duration(seconds: retryAfter.toInt()) : null,
      ),
      'ENVELOPE_TOO_LARGE' => const ChaoxingFailure(ChaoxingFailureCode.invalidInput, '凭据包太大，无法分享'),
      _ => ChaoxingFailure(ChaoxingFailureCode.server, '中转服务出错了（$status）'),
    };
  }

  // 只记路径不记查询串，与私信传输一个口径。
  void _log(String path, String errorType, Object error, StackTrace stack) {
    campusLog('[ChaoxingPack] action=request errorType=$errorType path=$path\n$stack');
  }

  void close() => _client.close();
}
