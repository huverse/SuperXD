import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:superxd/toolbox/short_video/parse_result.dart';
import 'package:superxd/toolbox/toolbox_models.dart';

class ParseHttp {
  ParseHttp({http.Client? client, this.timeout = const Duration(seconds: 25)})
    : _client = client ?? http.Client();
  final http.Client _client;
  final Duration timeout;
  static const payloadLimit = 1024 * 1024;

  Future<Map<String, dynamic>> get(
    Uri uri,
    ToolboxCancellation cancellation,
  ) async {
    if (cancellation.isCancelled) {
      throw const ParseFailure(ParseFailureCode.cancelled, '操作已取消');
    }
    final abort = Completer<void>();
    final request =
        http.AbortableRequest('GET', uri, abortTrigger: abort.future)
          ..followRedirects = false
          ..headers['Accept'] = 'application/json';
    try {
      return await Future.any([
        (() async {
          final response = await _client.send(request);
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
          if ((response.contentLength ?? 0) > payloadLimit) {
            throw const ParseFailure(ParseFailureCode.provider, '解析响应过大');
          }
          final bytes = <int>[];
          await for (final chunk in response.stream) {
            if (cancellation.isCancelled) {
              throw const ParseFailure(ParseFailureCode.cancelled, '操作已取消');
            }
            if (bytes.length + chunk.length > payloadLimit) {
              throw const ParseFailure(ParseFailureCode.provider, '解析响应过大');
            }
            bytes.addAll(chunk);
          }
          final result = jsonDecode(utf8.decode(bytes));
          if (result is! Map<String, dynamic>) {
            throw const ParseFailure(ParseFailureCode.provider, '解析服务返回了未知格式');
          }
          return result;
        })(),
        cancellation.signal.then<Map<String, dynamic>>(
          (_) => throw const ParseFailure(ParseFailureCode.cancelled, '操作已取消'),
        ),
      ]).timeout(
        timeout,
        onTimeout: () =>
            throw const ParseFailure(ParseFailureCode.timeout, '解析超时，请稍后重试'),
      );
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
    } finally {
      if (!abort.isCompleted) abort.complete();
    }
  }

  void close() => _client.close();
}
