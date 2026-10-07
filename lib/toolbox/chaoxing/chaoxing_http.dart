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

// 模拟的客户端：有的学校用的是定制版学习通（例如学在西电），课程列表只在对应客户端的身份下才对得上。
// 包名用于设备信息（读本机该客户端的版本与签名、报 app_name），UA 用于每个请求。
class ChaoxingClientProfile {
  const ChaoxingClientProfile({required this.id, required this.label, required this.userAgent, required this.packageName});
  final String id;
  final String label;
  final String userAgent;
  final String packageName;

  static const chaoxing = ChaoxingClientProfile(
    id: 'chaoxing',
    label: '学习通',
    userAgent: chaoxingUserAgent,
    packageName: 'com.chaoxing.mobile',
  );

  static const xuezaixidian = ChaoxingClientProfile(
    id: 'xuezaixidian',
    label: '学在西电',
    userAgent:
        'Mozilla/5.0 (Linux; Android 16; 23113RKC6C Build/BP2A.250605.031.A3; wv) AppleWebKit/537.36 (KHTML, like Gecko) '
        'Version/4.0 Chrome/147.0.7727.137 Mobile Safari/537.36 (schild:be536573b69ec1ae359e359d11f7f3e3) (device:23113RKC6C) '
        'Language/zh_CN com.chaoxing.mobile.xuezaixidian/ChaoXingStudy_1000149_6.3.7_android_phone_6005_249 '
        '(@Kalimdor)_f8777230ca1e45b2831ec7e36a9da1ea',
    packageName: 'com.chaoxing.mobile.xuezaixidian',
  );

  static const presets = [chaoxing, xuezaixidian];
  static const customId = 'custom';

  // 自定义 UA 只能是可打印 ASCII（请求头的限制）；包名可空，空时按学习通的包名算。
  static String? userAgentProblem(String value) {
    final text = value.trim();
    if (text.isEmpty) return '请填写 UserAgent';
    if (text.codeUnits.any((unit) => unit < 0x20 || unit > 0x7e)) return 'UserAgent 只能包含可打印的英文字符';
    return null;
  }

  factory ChaoxingClientProfile.custom({required String userAgent, String packageName = ''}) => ChaoxingClientProfile(
    id: customId,
    label: '自定义',
    userAgent: userAgent.trim(),
    packageName: packageName.trim().isEmpty ? chaoxing.packageName : packageName.trim(),
  );
}

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
    this.profile = ChaoxingClientProfile.chaoxing,
  }) : _client = client ?? http.Client(),
       cookies = cookies ?? ChaoxingCookieJar();

  static const payloadLimit = 1024 * 1024;

  final http.Client _client;
  final ChaoxingCookieJar cookies;
  final Duration timeout;

  // 模拟的客户端在设置里可换，换了之后已开着的会话也跟着换。
  ChaoxingClientProfile profile;

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
    request.headers['User-Agent'] = profile.userAgent;
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
