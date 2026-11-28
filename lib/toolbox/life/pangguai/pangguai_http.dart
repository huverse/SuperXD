import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:synchronized/synchronized.dart';

import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/campus_http.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_models.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_protocol.dart';

// 下单请求头里的设备与位置（胖乖按它核对人在不在设备旁，签名见 pangguaiRiskSign）。
typedef PangguaiRisk = ({String category, String imei, String latitude, String longitude});

// 胖乖接口的请求封装（经共用内核 CampusHttp，模块名 pangguai）：全是 POST（表单，饮水机的几个是 multipart），整次 15 秒、响应上限 1MB，
// 不跟随跳转、不自动重试。同一个服务的请求排队一个接一个发（同一时刻只有一个在路上），相邻两个的开始至少隔 spacing（200 毫秒，每秒最多 5 个）。
// 11-28 诊断包 TJEHRHFR：胖乖每个请求只要 100–300 毫秒，原来「上一个结束后再等 1 秒」（照移交包 Demo；移交包写明它的间隔只是测试节奏、
// 不是平台公布的安全配额）让点「下单」到拉起支付宝要 8 个请求、约 10 秒，连点几个档位时试算也排着队一个个等；官方 App 不这样等。
// 回 403、405、429 就停：这个域名 blockedFor 之内不再发任何请求（校园网出口共用 IP，撞了防火墙连同学的官方 App 一起受影响），拦截页不读。
// 凭据同时放请求头 Authorization 与表单 token（同官方 App）。日志只记路径与业务码，不记表单（有手机号、验证码、凭据）与回复。
class PangguaiHttp {
  PangguaiHttp({http.Client? client, this.spacing = const Duration(milliseconds: 200), this.timeout = const Duration(seconds: 15)}) : _http = CampusHttp('pangguai', client: client);

  static const payloadLimit = 1024 * 1024;
  static const blockedFor = Duration(minutes: 15);

  final CampusHttp _http;
  final Duration spacing;
  final Duration timeout;
  final _queue = Lock();
  var _last = DateTime.fromMillisecondsSinceEpoch(0);
  final _blockedUntil = <String, DateTime>{};

  // 胖乖自己的接口：业务码是整数 0 才算成，交回 data；2 是没登录。
  Future<Object?> post(String path, Map<String, String> fields, {String token = '', bool multipart = false, PangguaiRisk? risk}) async {
    final timestamp = '${DateTime.now().millisecondsSinceEpoch}';
    final headers = {
      'User-Agent': pangguaiUserAgent,
      'Authorization': token,
      'Version': pangguaiVersion,
      'channel': pangguaiChannel,
      'phoneBrand': pangguaiBrand,
      'timestamp': timestamp,
      'sign': pangguaiSign(path, token: token, timestamp: timestamp),
      if (risk != null) ...{
        'imei': risk.imei,
        'categoryCode': risk.category,
        'lat': risk.latitude,
        'lng': risk.longitude,
        'orderRiskTimestamp': timestamp,
        'orderRiskSign': pangguaiRiskSign(path, token: token, timestamp: timestamp, category: risk.category, imei: risk.imei, latitude: risk.latitude, longitude: risk.longitude),
      },
    };
    final body = await _send(Uri.parse('$pangguaiApi$path'), path, {...fields, if (token.isNotEmpty) 'token': token}, headers, multipart: multipart);
    final code = body['code'];
    if (code is int && code == 0) return body['data'];
    if (code == null) {
      campusLog('[Pangguai] action=json errorType=no_code path=$path');
      throw _unreadable;
    }
    throw _rejection(path, code, body['msg']);
  }

  // 饮水机合作方 apwork.cn 的接口：success 是 "success" 才算成，交回整个回复；"token" 是这次扫码给的会话过期了。
  Future<Map<String, Object?>> partner(String path, Map<String, String> fields) async {
    final body = await _send(Uri.parse('$pangguaiPartner$path'), path, fields, const {'User-Agent': pangguaiUserAgent, 'Referer': 'https://apwork.cn/ewash/water-qie/recharge.html'});
    final success = body['success'];
    if (success == 'success') return body;
    campusLog('[Pangguai] action=rejected path=$path code=${success is String && RegExp(r'^[a-z]{1,16}$').hasMatch(success) ? success : 'other'}');
    if (success == 'token') throw const PangguaiException(PangguaiFailure.rejected, '水卡会话过期了，重新打开这台饮水机', code: 'token');
    final message = body['msg'] ?? body['message'];
    throw PangguaiException(PangguaiFailure.rejected, message is String && message.trim().isNotEmpty ? message.trim() : '水卡服务没有办成，稍后再试', code: 'partner');
  }

  Future<Map<String, Object?>> _send(Uri uri, String path, Map<String, String> fields, Map<String, String> headers, {bool multipart = false}) => _queue.synchronized(() async {
    final until = _blockedUntil[uri.host];
    if (until != null && DateTime.now().isBefore(until)) throw _blocked(until);
    final wait = spacing - DateTime.now().difference(_last);
    if (wait > Duration.zero) await Future<void>.delayed(wait);
    _last = DateTime.now();
    final http.Response response;
    try {
      response = await _http.send(
        'POST',
        uri,
        timeout: timeout,
        limit: payloadLimit,
        followRedirects: false,
        headers: multipart ? headers : {...headers, 'Content-Type': 'application/x-www-form-urlencoded; charset=utf-8'},
        body: multipart ? null : Uri(queryParameters: fields).query,
        multipart: multipart ? (fields: fields, files: const []) : null,
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
    if (const {403, 405, 429}.contains(response.statusCode)) {
      final until = DateTime.now().add(blockedFor);
      _blockedUntil[uri.host] = until;
      campusLog('[Pangguai] action=blocked path=$path status=${response.statusCode}');
      throw _blocked(until);
    }
    if (response.statusCode != 200) {
      campusLog('[Pangguai] action=http errorType=status path=$path status=${response.statusCode}');
      throw PangguaiException(PangguaiFailure.network, '胖乖生活暂时不可用（${response.statusCode}）');
    }
    try {
      final json = jsonDecode(utf8.decode(response.bodyBytes));
      if (json is Map) return json.cast<String, Object?>();
      campusLog('[Pangguai] action=json errorType=not_object path=$path');
    } on FormatException catch (error) {
      campusLog('[Pangguai] action=json errorType=${error.runtimeType} path=$path length=${response.bodyBytes.length}');
    }
    throw _unreadable;
  });

  static const _unreadable = PangguaiException(PangguaiFailure.invalidResponse, '胖乖生活的返回看不懂，稍后再试');
  static const _offline = PangguaiException(PangguaiFailure.network, '连不上胖乖生活，检查一下网络');

  PangguaiException _blocked(DateTime until) => PangguaiException(PangguaiFailure.blocked, '胖乖生活暂时拒绝访问，${formatCampusClock(until)} 以后再试');

  void _log(String path, String errorType, Object error, StackTrace stack) => campusLog('[Pangguai] action=http errorType=$errorType path=$path\n$stack');

  void close() => _http.close();
}

// 业务码不是 0 的回复换成异常：2 是没登录或登录失效；其余照写胖乖的原话（msg），没有原话时写业务码。日志只记数字业务码。
PangguaiException _rejection(String path, Object code, Object? msg) {
  final codeText = code is int || (code is String && RegExp(r'^-?\d{1,8}$').hasMatch(code)) ? '$code' : 'other';
  campusLog('[Pangguai] action=rejected path=$path code=$codeText');
  if (codeText == '2') return const PangguaiException(PangguaiFailure.notSignedIn, '登录过期了，请重新登录', code: '2');
  final text = msg is String ? msg.trim() : '';
  return PangguaiException(PangguaiFailure.rejected, text.isNotEmpty && text != '成功' ? text : '胖乖生活没有办成（$codeText）', code: codeText);
}
