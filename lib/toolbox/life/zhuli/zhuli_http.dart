import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/campus_http.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/toolbox/life/life_http_brake.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_models.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_protocol.dart';

// 住理接口的请求封装（经共用内核 CampusHttp，模块名 zhuli）：只发 GET，整次 15 秒、响应上限 1MB，不自动重试；
// 请求策略同生活下面的其他子模块（人工决策见 life_http_brake.dart）：不排队、不限并发，回 403、405、429 就停这个域名 15 分钟（11-28 起，原来没有这一道）；
// 日志只记路径与住理的错误码，不记查询串（里面有手机号、密码与签名）、不记回复内容。
class ZhuliHttp {
  ZhuliHttp({http.Client? client, this.timeout = const Duration(seconds: 15)}) : _http = CampusHttp('zhuli', client: client);

  static const payloadLimit = 1024 * 1024;

  final CampusHttp _http;
  final Duration timeout;
  final _brake = LifeHttpBrake();

  // 发一次签名的 GET，回复的 data（已解开 base64）；result 为假时按错误码与文案抛 ZhuliException。
  Future<Object?> get(Uri base, String path, Map<String, Object?> params, {required String key, Map<String, Object> common = const {}}) async {
    final uri = base.replace(path: '${base.path}$path', queryParameters: zhuliQuery(params, key: key, common: common));
    if (_brake.blockedUntil(uri.host) case final until?) throw _blocked(until);
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
    if (_brake.observe(uri.host, response.statusCode) case final until?) {
      campusLog('[Zhuli] action=blocked path=$path status=${response.statusCode}');
      throw _blocked(until);
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

  ZhuliException _blocked(DateTime until) => ZhuliException(ZhuliFailure.blocked, '住理生活暂时拒绝访问，${formatCampusClock(until)} 以后再试');

  void _log(String path, String errorType, Object error, StackTrace stack) => campusLog('[Zhuli] action=http errorType=$errorType path=$path\n$stack');

  void close() => _http.close();
}

// result 为假的回复换成异常：err_msg 是错误码（login_timeout、api_sign_error…），msg 是给人看的中文。
ZhuliException zhuliRejection(String path, Map<String, Object?> body) {
  final code = body['err_msg'] is String ? body['err_msg']! as String : '';
  final text = body['msg'] is String ? (body['msg']! as String).trim() : '';
  // 错误码只记英文的那种（中文文案可能带手机号之类，不进日志）。
  campusLog('[Zhuli] action=rejected path=$path code=${RegExp(r'^[a-z_]{1,48}$').hasMatch(code) ? code : 'text'}');
  if (code == 'login_timeout') return const ZhuliException(ZhuliFailure.sessionExpired, '登录过期了，请重新登录', code: 'login_timeout');
  // 在住理官方 App 或别的设备上登录同一个账号，住理会换掉这个账号的 session_secret，手上这份会话签的请求一律回 api_sign_error
  // （11-24 用户真机诊断包：官方 App 一键登录后回到本应用，四个首页请求全是它）。同会话过期，重登一次再重放；重登后还是它才照写给用户看。
  if (code == 'api_sign_error') return const ZhuliException(ZhuliFailure.sessionExpired, '请求校验没通过，稍后再试', code: 'api_sign_error');
  // 登录时住理要图形验证码（原 App account 页认这三种）。
  if (const {'本次登录需要进行验证', 'CAPTCHA_REQUIRED', '验证码输入错误'}.contains(text) || const {'本次登录需要进行验证', 'CAPTCHA_REQUIRED', '验证码输入错误'}.contains(code)) {
    return ZhuliException(ZhuliFailure.captchaRequired, text == '验证码输入错误' || code == '验证码输入错误' ? '验证码不对，换一张再输' : '请输入图形验证码');
  }
  final message = text.isNotEmpty ? text : switch (code) {
    'device_not_exists' => '设备不存在',
    '' => '住理生活没有办成，稍后再试',
    _ when !RegExp(r'^[a-z_]+$').hasMatch(code) => code,
    _ => '住理生活没有办成（$code）',
  };
  return ZhuliException(ZhuliFailure.rejected, message, code: code);
}
