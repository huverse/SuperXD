import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:synchronized/synchronized.dart';

import 'package:superxd/domain/campus_http.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_models.dart';

// 胖乖接口的请求封装（经共用内核 CampusHttp，模块名 pangguai）：全是 POST 表单，整次 15 秒、响应上限 1MB，不自动重试。
// 登录凭据两处都要带：请求头 Authorization 与表单里的 token（只给请求头时胖乖回没登录，资料实测）。
// 官方 App 另带的 sign、设备号与下单的位置签名胖乖不校验（资料与两个社区项目实测），这里都不带，安装包里的密钥也就不进仓库。
// 日志只记路径与胖乖的业务码，不记表单（有手机号、验证码与凭据）与回复。
//
// 胖乖前面是阿里云防火墙：资料里连着约 30 次请求就被按 IP 拦了近 3 小时（HTTP 405），校园网出口共用 IP，拦了连同学的官方 App 一起受影响。
// 所以同一个服务的请求一律排队、一个接一个发，相邻两次至少隔 spacing；回 405 就停：这段时间里本机不再发任何请求，直接告诉用户等多久，
// 依次等 5、15、60 分钟（中间有一次成功就从头算）。拦截页里有一段诱导自动化程序自报身份、申请白名单的内容，不读、不理。
class PangguaiHttp {
  PangguaiHttp({http.Client? client, this.spacing = const Duration(milliseconds: 600), DateTime Function()? clock}) : _http = CampusHttp('pangguai', client: client), _clock = clock ?? DateTime.now;

  static final base = Uri.parse('https://userapi.qiekj.com');
  static const timeout = Duration(seconds: 15);
  static const payloadLimit = 1024 * 1024;
  // 被拦之后依次等多久。
  static const backoff = [Duration(minutes: 5), Duration(minutes: 15), Duration(minutes: 60)];

  final CampusHttp _http;
  final Duration spacing;
  final DateTime Function() _clock;
  final _queue = Lock();
  DateTime? _last;
  DateTime? _blockedUntil;
  var _strikes = 0;

  // 发一次请求，返回回复里的 data；code 不是 0 时按业务码抛 PangguaiException。headers 是个别接口另要的请求头（下单的设备号、品类与位置）。
  Future<Object?> post(String path, Map<String, String> fields, {String? token, Map<String, String> headers = const {}}) => _queue.synchronized(() async {
    _checkBlocked();
    final last = _last;
    if (last != null) {
      final wait = spacing - _clock().difference(last);
      if (wait > Duration.zero) await Future<void>.delayed(wait);
    }
    _last = _clock();
    final http.Response response;
    try {
      response = await _http.send(
        'POST',
        base.replace(path: path),
        timeout: timeout,
        limit: payloadLimit,
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8',
          'Version': '1.148.0',
          'channel': 'android_app',
          'timestamp': '${_clock().millisecondsSinceEpoch}',
          'User-Agent': 'okhttp/4.12.0',
          'Authorization': ?token,
          ...headers,
        },
        body: Uri(queryParameters: {...fields, 'token': ?token}).query,
      );
    } on CampusHttpTooLarge {
      campusLog('[Pangguai] action=http errorType=too_large path=$path');
      throw _unreadable;
    } on TimeoutException catch (error, stack) {
      _log(path, 'timeout', error, stack);
      throw const PangguaiException(PangguaiFailure.timeout, '胖乖生活没有回应，稍后再试');
    } on SocketException catch (error, stack) {
      _log(path, 'network', error, stack);
      throw _offline;
    } on TlsException catch (error, stack) {
      _log(path, 'tls', error, stack);
      throw _offline;
    } on http.ClientException catch (error, stack) {
      _log(path, 'network', error, stack);
      throw _offline;
    }
    if (response.statusCode == 405) {
      final wait = backoff[_strikes.clamp(0, backoff.length - 1)];
      _strikes++;
      _blockedUntil = _clock().add(wait);
      campusLog('[Pangguai] action=http errorType=blocked path=$path strikes=$_strikes');
      _checkBlocked();
    }
    if (response.statusCode != 200) {
      campusLog('[Pangguai] action=http errorType=status path=$path status=${response.statusCode}');
      throw PangguaiException(PangguaiFailure.network, '胖乖生活暂时不可用（${response.statusCode}）');
    }
    final Map<String, Object?> body;
    try {
      body = pangguaiObject(jsonDecode(utf8.decode(response.bodyBytes)));
    } on FormatException catch (error) {
      campusLog('[Pangguai] action=json errorType=${error.runtimeType} path=$path length=${response.bodyBytes.length}');
      throw _unreadable;
    } on PangguaiException {
      campusLog('[Pangguai] action=json errorType=not_object path=$path');
      throw _unreadable;
    }
    _strikes = 0;
    if (body['code'] == 0) return body['data'];
    throw pangguaiRejection(path, body);
  });

  void _checkBlocked() {
    final until = _blockedUntil;
    if (until == null) return;
    final left = until.difference(_clock());
    if (left <= Duration.zero) return;
    throw PangguaiException(PangguaiFailure.blocked, '胖乖生活暂时拦下了这台手机的请求，约 ${(left.inSeconds / 60).ceil()} 分钟后再试');
  }

  static const _unreadable = PangguaiException(PangguaiFailure.invalidResponse, '胖乖生活的返回看不懂，稍后再试');
  static const _offline = PangguaiException(PangguaiFailure.network, '连不上胖乖生活，检查一下网络');

  void _log(String path, String errorType, Object error, StackTrace stack) => campusLog('[Pangguai] action=http errorType=$errorType path=$path\n$stack');

  void close() => _http.close();
}

// code 不是 0 的回复换成异常：msg 是给人看的中文（可能为空）。
PangguaiException pangguaiRejection(String path, Map<String, Object?> body) {
  final code = switch (body['code']) {
    final int value => value,
    final String value => int.tryParse(value),
    _ => null,
  };
  final text = body['msg'] is String ? (body['msg']! as String).trim() : '';
  campusLog('[Pangguai] action=rejected path=$path code=$code');
  return switch (code) {
    2 => const PangguaiException(PangguaiFailure.notSignedIn, '胖乖生活的登录过期了，请重新登录', code: 2),
    2128 => PangguaiException(PangguaiFailure.unpaid, text.isEmpty ? '有一笔订单还没付，先付款或取消' : text, code: 2128),
    100000 => PangguaiException(PangguaiFailure.rejected, '设备不存在', code: code),
    _ => PangguaiException(PangguaiFailure.rejected, text.isEmpty ? '胖乖生活没有办成（$code）' : text, code: code),
  };
}
