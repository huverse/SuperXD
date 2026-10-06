import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';

// 学习通 Android 客户端的 User-Agent，接口按这个身份分发响应。
const chaoxingUserAgent =
    'Dalvik/2.1.0 (Linux; U; Android 12; SM-N9006 Build/8aba9e4.0) '
    '(schild:2d97f7b9439f21333c946878fc4d6ccb) (device:SM-N9006) Language/zh_CN '
    'com.chaoxing.mobile/ChaoXingStudy_3_6.7.5_android_phone_10941_314 (@Kalimdor)_68f184fd763546c1a04ab3a09b3deebb';

class ChaoxingResponse {
  const ChaoxingResponse(this.statusCode, this.bytes);
  final int statusCode;
  final Uint8List bytes;

  // 验证码底图这类响应要原始字节，其余按 UTF-8 文本读。
  String get body => utf8.decode(bytes, allowMalformed: true);
}

// chaoxing.com 域下的 Cookie 按登录会话单独维护：登录响应整体覆盖，用户信息响应按名合并，
// 其他域各存各的。这样切换学校（fid）时只改会话里的 fid，不会串到别的域。
class ChaoxingCookieJar {
  ChaoxingCookieJar({Map<String, String>? session}) {
    if (session != null) _chaoxing.addAll(session);
  }
  final _chaoxing = <String, String>{};
  final _hosts = <String, Map<String, String>>{};

  Map<String, String> get session => Map.unmodifiable(_chaoxing);

  void restore(Map<String, String> session) {
    _chaoxing
      ..clear()
      ..addAll(session);
  }

  String? operator [](String name) => _chaoxing[name];

  void set(String name, String value) => _chaoxing[name] = value;

  void save(Uri url, Map<String, String> cookies) {
    if (cookies.isEmpty) return;
    if (url.host.endsWith('chaoxing.com')) {
      if (url.path == '/fanyalogin') {
        _chaoxing
          ..clear()
          ..addAll(cookies);
      } else if (url.path == '/apis/login/userLogin4Uname.do') {
        _chaoxing.addAll(cookies);
      }
      return;
    }
    _hosts[url.host] = Map.of(cookies);
  }

  Map<String, String> load(Uri url) => url.host.endsWith('chaoxing.com')
      ? Map.of(_chaoxing)
      : Map.of(_hosts[url.host] ?? const {});

  static Map<String, String> parseSetCookie(List<String> headers) {
    final cookies = <String, String>{};
    for (final header in headers) {
      final pair = header.split(';').first;
      final index = pair.indexOf('=');
      if (index <= 0) continue;
      cookies[pair.substring(0, index).trim()] = pair.substring(index + 1).trim();
    }
    return cookies;
  }
}

class ChaoxingHttp {
  ChaoxingHttp({
    http.Client? client,
    ChaoxingCookieJar? cookies,
    this.timeout = const Duration(seconds: 15),
  }) : _client = client ?? http.Client(),
       cookies = cookies ?? ChaoxingCookieJar();

  static const payloadLimit = 1024 * 1024;

  final http.Client _client;
  final ChaoxingCookieJar cookies;
  final Duration timeout;

  Future<ChaoxingResponse> get(Uri uri, {Duration? timeout, Map<String, String>? headers}) =>
      _send('GET', uri, headers: headers, timeout: timeout);

  Future<Uint8List> getBytes(Uri uri, {Duration? timeout}) async =>
      (await _send('GET', uri, timeout: timeout)).bytes;

  Future<ChaoxingResponse> postForm(
    Uri uri,
    String body, {
    String contentType = 'application/x-www-form-urlencoded; charset=UTF-8',
    Map<String, String>? headers,
    Duration? timeout,
  }) => _send('POST', uri, body: body, contentType: contentType, headers: headers, timeout: timeout);

  Future<ChaoxingResponse> postMultipart(
    Uri uri, {
    required Map<String, String> fields,
    required String filename,
    required List<int> bytes,
    required String contentType,
    Duration? timeout,
  }) async {
    final request = http.MultipartRequest('POST', uri)
      ..fields.addAll(fields)
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename, contentType: http.MediaType.parse(contentType)));
    return _send('POST', uri, multipart: request, timeout: timeout);
  }

  Future<ChaoxingResponse> _send(
    String method,
    Uri uri, {
    String? body,
    String? contentType,
    Map<String, String>? headers,
    http.MultipartRequest? multipart,
    Duration? timeout,
  }) async {
    final limit = timeout ?? this.timeout;
    final request = multipart ?? http.Request(method, uri);
    request.headers['User-Agent'] = chaoxingUserAgent;
    request.headers['Accept'] = '*/*';
    if (headers != null) request.headers.addAll(headers);
    final loaded = cookies.load(uri);
    if (loaded.isNotEmpty) {
      request.headers['Cookie'] = loaded.entries.map((entry) => '${entry.key}=${entry.value}').join('; ');
    }
    if (multipart == null && body != null) {
      if (contentType != null) request.headers['Content-Type'] = contentType;
      (request as http.Request).body = body;
    }
    try {
      final response = await _client.send(request).timeout(limit);
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(limit)) {
        bytes.addAll(chunk);
        if (bytes.length > payloadLimit) {
          throw const ChaoxingFailure(ChaoxingFailureCode.invalidResponse, '响应过大，已停止读取');
        }
      }
      cookies.save(uri, ChaoxingCookieJar.parseSetCookie(response.headersSplitValues['set-cookie'] ?? const []));
      if (response.statusCode >= 400) {
        throw ChaoxingFailure(ChaoxingFailureCode.server, '学习通返回错误码 ${response.statusCode}');
      }
      return ChaoxingResponse(response.statusCode, Uint8List.fromList(bytes));
    } on ChaoxingFailure {
      rethrow;
    } on TimeoutException catch (error, stack) {
      _log(uri, 'timeout', error, stack);
      throw const ChaoxingFailure(ChaoxingFailureCode.timeout, '请求超时，请稍后重试');
    } on SocketException catch (error, stack) {
      _log(uri, 'network', error, stack);
      throw const ChaoxingFailure(ChaoxingFailureCode.network, '网络连接失败，请检查网络');
    } on http.ClientException catch (error, stack) {
      _log(uri, 'network', error, stack);
      throw const ChaoxingFailure(ChaoxingFailureCode.network, '网络请求未完成，请稍后重试');
    }
  }

  // 只记路径不记查询串：签到参数里有 enc 与坐标。
  void _log(Uri uri, String errorType, Object error, StackTrace stack) {
    campusLog('[Chaoxing] action=http errorType=$errorType path=${uri.path}\n$stack');
  }

  void close() => _client.close();
}

// 表单体按标准表单编码：登录的密文里有 + 与 =，签到活动的 ext 是 JSON，都要编码后再拼。
String chaoxingFormBody(Map<String, String> fields) => fields.entries
    .map((entry) => '${Uri.encodeQueryComponent(entry.key)}=${Uri.encodeQueryComponent(entry.value)}')
    .join('&');

Map<String, Object?> chaoxingJson(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map) return decoded.cast<String, Object?>();
  } on FormatException {
    // 落到下面的统一错误
  }
  throw const ChaoxingFailure(ChaoxingFailureCode.invalidResponse, '学习通返回了未知格式');
}

Map<String, Object?> chaoxingData(String body) {
  final data = chaoxingJson(body)['data'];
  if (data is Map) return data.cast<String, Object?>();
  throw const ChaoxingFailure(ChaoxingFailureCode.invalidResponse, '学习通返回了未知格式');
}

int chaoxingInt(Object? value, {int fallback = 0}) =>
    value is num ? value.toInt() : int.tryParse('$value') ?? fallback;

double? chaoxingDouble(Object? value) => value is num ? value.toDouble() : double.tryParse('${value ?? ''}');

String chaoxingString(Object? value, {String fallback = ''}) =>
    value == null ? fallback : '$value';
