import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'package:superxd/domain/campus_http.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/toolbox/express/express_models.dart';

class ExpressResponse {
  const ExpressResponse(this.statusCode, this.bytes, {this.headers = const {}});
  final int statusCode;
  final Uint8List bytes;
  // 响应头（键小写）；短信登录要从 set-cookie 里取会话，同名的多条被合成一行、以逗号隔开。
  final Map<String, String> headers;

  String get body => utf8.decode(bytes, allowMalformed: true);
}

// 拼多多接口的请求封装：显式超时管整个请求（连接、发送、读完响应体），响应上限 1MB，日志只记路径；超时、上限与请求记录在共用内核 CampusHttp。
// 不维护 Cookie 会话——登录态由 PddSession 的请求头整体带上，各请求无状态。
class ExpressHttp {
  ExpressHttp({http.Client? client, this.timeout = const Duration(seconds: 15)}) : _http = CampusHttp('express', client: client);

  static const payloadLimit = 1024 * 1024;

  final CampusHttp _http;
  final Duration timeout;

  Future<ExpressResponse> getJson(Uri uri, {required Map<String, String> headers}) =>
      _send('GET', uri, headers: headers);

  // errorBody：4xx 也照常交回响应体（登录接口的失败原因与验证令牌在 4xx 的 JSON 里），由调用方按错误码分支。
  Future<ExpressResponse> postJson(Uri uri, {required Map<String, String> headers, required Map<String, Object?> body, bool errorBody = false}) =>
      _send('POST', uri, headers: headers, body: jsonEncode(body), errorBody: errorBody);

  Future<ExpressResponse> _send(String method, Uri uri, {required Map<String, String> headers, String? body, bool errorBody = false}) async {
    try {
      final response = await _http.send(method, uri, timeout: timeout, limit: payloadLimit, headers: headers, body: body);
      if (errorBody && response.statusCode < 500) return ExpressResponse(response.statusCode, response.bodyBytes, headers: response.headers);
      if (response.statusCode >= 400) {
        campusLog('[Express] action=http errorType=status path=${uri.path} status=${response.statusCode}');
        // 401/424：异地登录等把会话顶掉时拼多多返回的 HTTP 状态（真机实测 station/package 在被挤下线后回 424），
        // 归未登录、回到登录页，而不是弹原始状态码。其余 4xx/5xx 仍按服务器错误。
        if (response.statusCode == 401 || response.statusCode == 424) {
          throw const ExpressFailure(ExpressFailureCode.notLoggedIn, '登录已失效，请重新登录');
        }
        throw ExpressFailure(ExpressFailureCode.server, '拼多多返回错误码 ${response.statusCode}');
      }
      return ExpressResponse(response.statusCode, response.bodyBytes, headers: response.headers);
    } on ExpressFailure {
      rethrow;
    } on CampusHttpTooLarge {
      campusLog('[Express] action=http errorType=too_large path=${uri.path} limit=$payloadLimit');
      throw const ExpressFailure(ExpressFailureCode.tooLarge, '响应过大，已停止读取');
    } on TimeoutException catch (error, stack) {
      _log(uri, 'timeout', error, stack);
      throw const ExpressFailure(ExpressFailureCode.timeout, '请求超时，请稍后重试');
    } on SocketException catch (error, stack) {
      _log(uri, 'network', error, stack);
      throw const ExpressFailure(ExpressFailureCode.network, '网络连接失败，请检查网络');
    } on TlsException catch (error, stack) {
      _log(uri, 'tls', error, stack);
      throw const ExpressFailure(ExpressFailureCode.network, '网络连接失败，请检查网络');
    } on http.ClientException catch (error, stack) {
      _log(uri, 'network', error, stack);
      throw const ExpressFailure(ExpressFailureCode.network, '网络请求未完成，请稍后重试');
    }
  }

  // 只记路径不记查询串与请求体：身份码与会话凭据不入日志。error 入签名保持捕获变量被用到，正文只打类型与堆栈。
  void _log(Uri uri, String errorType, Object error, StackTrace stack) =>
      campusLog('[Express] action=http errorType=$errorType path=${uri.path}\n$stack');

  void close() => _http.close();
}

// 认不出的格式记一行（只记类型与长度，不记响应内容）：拼多多改版时最先坏在这里。
Map<String, Object?> expressJson(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map) return decoded.cast<String, Object?>();
    campusLog('[Express] action=json errorType=not_object type=${decoded.runtimeType}');
  } on FormatException catch (error) {
    campusLog('[Express] action=json errorType=${error.runtimeType} length=${body.length}');
  }
  throw const ExpressFailure(ExpressFailureCode.invalidResponse, '无法识别拼多多的返回');
}
