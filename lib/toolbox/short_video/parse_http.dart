import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:superxd/domain/campus_http.dart';
import 'package:superxd/toolbox/short_video/parse_result.dart';
import 'package:superxd/toolbox/toolbox_models.dart';

// 解析接口的请求封装：超时管到读完响应体、响应上限 1MB、取消即中断连接，都在共用内核 CampusHttp；这里只把结果映射成 ParseFailure。
class ParseHttp {
  ParseHttp({http.Client? client, this.timeout = const Duration(seconds: 25)})
    : _http = CampusHttp('short_video', client: client);
  final CampusHttp _http;
  final Duration timeout;
  static const payloadLimit = 1024 * 1024;

  Future<Map<String, dynamic>> get(
    Uri uri,
    ToolboxCancellation cancellation,
  ) async {
    if (cancellation.isCancelled) {
      throw const ParseFailure(ParseFailureCode.cancelled, '操作已取消');
    }
    // 开发者模式下记一条路径、状态、耗时与字节数（内核按 campusRequestLog 记，不记查询串里的作品链接）。
    try {
      final response = await _http.send(
        'GET',
        uri,
        timeout: timeout,
        limit: payloadLimit,
        headers: const {'Accept': 'application/json'},
        followRedirects: false,
        cancel: cancellation.signal,
      );
      if (response.statusCode == 429) {
        final seconds = int.tryParse(response.headers['retry-after'] ?? '');
        throw ParseFailure(
          ParseFailureCode.rateLimited,
          '解析服务限流，请稍后再试',
          retryAfter: Duration(seconds: (seconds ?? 30).clamp(1, 300)),
        );
      }
      if (response.statusCode != 200) {
        throw const ParseFailure(ParseFailureCode.provider, '解析服务暂不可用');
      }
      final result = jsonDecode(utf8.decode(response.bodyBytes));
      if (result is! Map<String, dynamic>) {
        throw const ParseFailure(ParseFailureCode.provider, '解析服务返回了未知格式');
      }
      return result;
    } on CampusHttpTooLarge {
      throw const ParseFailure(ParseFailureCode.provider, '解析响应过大');
    } on TimeoutException {
      throw const ParseFailure(ParseFailureCode.timeout, '解析超时，请稍后重试');
    } on http.RequestAbortedException {
      throw const ParseFailure(ParseFailureCode.cancelled, '操作已取消');
    } on FormatException catch (error, stack) {
      Error.throwWithStackTrace(
        const ParseFailure(ParseFailureCode.provider, '解析服务返回了未知格式'),
        stack,
      );
    } on http.ClientException catch (error, stack) {
      Error.throwWithStackTrace(
        const ParseFailure(ParseFailureCode.network, '网络请求未完成，请稍后重试'),
        stack,
      );
    }
  }

  void close() => _http.close();
}
