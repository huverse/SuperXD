import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'package:superxd/domain/campus_http.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_models.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_protocol.dart';

// 住理接口的请求封装（经共用内核 CampusHttp，模块名 zhuli）：只发 GET，整次 15 秒、响应上限 1MB，不自动重试；
// 日志只记路径与住理的错误码，不记查询串（里面有手机号、密码与签名）、不记回复内容。
class ZhuliHttp {
  ZhuliHttp({http.Client? client, this.timeout = const Duration(seconds: 15)}) : _http = CampusHttp('zhuli', client: client);

  static const payloadLimit = 1024 * 1024;

  final CampusHttp _http;
  final Duration timeout;

  // 发一次签名的 GET，回复的 data（已解开 base64）；result 为假时按错误码与文案抛 ZhuliException。
  Future<Object?> get(Uri base, String path, Map<String, Object?> params, {required String key, Map<String, Object> common = const {}}) async {
    final uri = base.replace(path: '${base.path}$path', queryParameters: zhuliQuery(params, key: key, common: common));
    final http.Response response;
    try {
      response = await _http.send('GET', uri, timeout: timeout, limit: payloadLimit, headers: const {'Content-Type': 'application/json'});
    } on CampusHttpTooLarge {
      campusLog('[Zhuli] action=http errorType=too_large path=$path');
      throw _unreadable;
    } on TimeoutException catch (error, stack) {
      _log(path, 'timeout', error, stack);
      throw const ZhuliException(ZhuliFailure.timeout, '住理生活没有回应，稍后再试');
    } on SocketException catch (error, stack) {
      _log(path, 'network', error, stack);
      throw const ZhuliException(ZhuliFailure.network, '连不上住理生活，检查一下网络');
    } on TlsException catch (error, stack) {
      _log(path, 'tls', error, stack);
      throw const ZhuliException(ZhuliFailure.network, '连不上住理生活，检查一下网络');
    } on http.ClientException catch (error, stack) {
      _log(path, 'network', error, stack);
      throw const ZhuliException(ZhuliFailure.network, '连不上住理生活，检查一下网络');
    }
    if (response.statusCode != 200) {
      campusLog('[Zhuli] action=http errorType=status path=$path status=${response.statusCode}');
      throw ZhuliException(ZhuliFailure.network, '住理生活暂时不可用（${response.statusCode}）');
    }
    final Map<String, Object?> body;
    try {
      body = zhuliObject(jsonDecode(utf8.decode(response.bodyBytes)));
      if (body['result'] == true) return zhuliDecodeData(body['data']);
    } on FormatException catch (error) {
      campusLog('[Zhuli] action=json errorType=${error.runtimeType} path=$path length=${response.bodyBytes.length}');
      throw _unreadable;
    } on ZhuliException {
      campusLog('[Zhuli] action=json errorType=not_object path=$path');
      throw _unreadable;
    }
    throw zhuliRejection(path, body);
  }

  static const _unreadable = ZhuliException(ZhuliFailure.invalidResponse, '住理生活的返回看不懂，稍后再试');

  void _log(String path, String errorType, Object error, StackTrace stack) => campusLog('[Zhuli] action=http errorType=$errorType path=$path\n$stack');

  void close() => _http.close();
}

// result 为假的回复换成异常：err_msg 是错误码（login_timeout、api_sign_error…），msg 是给人看的中文。
ZhuliException zhuliRejection(String path, Map<String, Object?> body) {
  final code = body['err_msg'] is String ? body['err_msg']! as String : '';
  final text = body['msg'] is String ? (body['msg']! as String).trim() : '';
  // 错误码只记英文的那种（中文文案可能带手机号之类，不进日志）。
  campusLog('[Zhuli] action=rejected path=$path code=${RegExp(r'^[a-z_]{1,48}$').hasMatch(code) ? code : 'text'}');
  if (code == 'login_timeout') return const ZhuliException(ZhuliFailure.sessionExpired, '登录过期了，请重新登录');
  // 登录时住理要图形验证码（原 App account 页认这三种）。
  if (const {'本次登录需要进行验证', 'CAPTCHA_REQUIRED', '验证码输入错误'}.contains(text) || const {'本次登录需要进行验证', 'CAPTCHA_REQUIRED', '验证码输入错误'}.contains(code)) {
    return ZhuliException(ZhuliFailure.captchaRequired, text == '验证码输入错误' || code == '验证码输入错误' ? '验证码不对，换一张再输' : '请输入图形验证码');
  }
  final message = text.isNotEmpty ? text : switch (code) {
    'api_sign_error' => '请求校验没通过，稍后再试',
    'device_not_exists' => '设备不存在',
    '' => '住理生活没有办成，稍后再试',
    _ when !RegExp(r'^[a-z_]+$').hasMatch(code) => code,
    _ => '住理生活没有办成（$code）',
  };
  return ZhuliException(ZhuliFailure.rejected, message);
}
