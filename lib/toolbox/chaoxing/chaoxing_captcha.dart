import 'dart:convert';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import 'package:superxd/toolbox/chaoxing/chaoxing_client.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_crypto.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_http.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';

// 学习通的滑块验证码：先取底图与缺口图，用户拖到位后换一次性的 validate，随签到提交回去。
// 三个接口都是 JSONP，响应外面裹着 cx_captcha_function(...)。
const chaoxingCaptchaId = 'Qt9FIw9o4pwRjOyqM6yizZBh682qN2TU';
const chaoxingCaptchaType = 'slide';
const chaoxingCaptchaVersion = '1.1.20';
const chaoxingCaptchaTokenWindow = 300000;
const chaoxingCaptchaConfUri = 'https://captcha.chaoxing.com/captcha/get/conf';
const chaoxingCaptchaImageUri = 'https://captcha.chaoxing.com/captcha/get/verification/image';
const chaoxingCaptchaResultUri = 'https://captcha.chaoxing.com/captcha/check/verification/result';

String chaoxingJsonp(String body) {
  final start = body.indexOf('(');
  final end = body.lastIndexOf(')');
  return start >= 0 && end > start ? body.substring(start + 1, end) : body;
}

// 学习通验证码的坐标空间是 280 宽，x 还带 -8 的边校正（参考项目实测值）。
const chaoxingCaptchaCanvasWidth = 280.0;
const chaoxingCaptchaEdgeOffset = -8.0;

class ChaoxingCaptchaPuzzle {
  const ChaoxingCaptchaPuzzle({
    required this.token,
    required this.iv,
    required this.shadeImageUrl,
    required this.cutoutImageUrl,
  });
  final String token;
  final String iv;

  // 底图与缺口块都是图片地址，取回后当普通图片显示。
  final String shadeImageUrl;
  final String cutoutImageUrl;
}

// 滑块从最左拖到最右对应的提交坐标：拖动行程是图片宽减去缺口块宽。
double chaoxingCaptchaPosition(double pieceLeft, double travel) => travel <= 0
    ? chaoxingCaptchaEdgeOffset
    : (pieceLeft / travel) * chaoxingCaptchaCanvasWidth + chaoxingCaptchaEdgeOffset;

Future<Uint8List> chaoxingCaptchaImage(ChaoxingClient client, String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme) {
    throw const ChaoxingFailure(ChaoxingFailureCode.captchaRequired, '验证码图片地址不正确');
  }
  return client.http.getBytes(uri);
}

class ChaoxingCaptchaAnswer {
  const ChaoxingCaptchaAnswer({required this.passed, this.validate, this.message});
  final bool passed;
  final String? validate;
  final String? message;
}

// 时间戳、随机数都走同一次取值的口径，token 与 iv 的拼接顺序是对方的协议事实。
Future<ChaoxingCaptchaPuzzle> chaoxingCaptchaPuzzle(
  ChaoxingClient client, {
  required Uri referer,
  String Function()? uuid,
}) async {
  final now = DateTime.now().millisecondsSinceEpoch;
  final uniqueId = uuid ?? const Uuid().v4;
  final t = await _chaoxingCaptchaConf(client, now);
  final captchaKey = chaoxingMd5('$t${uniqueId()}');
  final iv = chaoxingMd5('$chaoxingCaptchaId$chaoxingCaptchaType$now${uniqueId()}');
  final token = '${chaoxingMd5('$t$chaoxingCaptchaId$chaoxingCaptchaType$captchaKey')}:${t + chaoxingCaptchaTokenWindow}';
  final response = await client.http.get(
    Uri.parse(chaoxingCaptchaImageUri).replace(
      queryParameters: {
        'callback': 'cx_captcha_function',
        'captchaId': chaoxingCaptchaId,
        'type': chaoxingCaptchaType,
        'version': chaoxingCaptchaVersion,
        'captchaKey': captchaKey,
        'token': token,
        'referer': referer.toString(),
        'iv': iv,
        '_': '$now',
      },
    ),
  );
  final json = chaoxingJson(chaoxingJsonp(response.body));
  final verification = json['imageVerificationVo'];
  if (verification is! Map) {
    throw const ChaoxingFailure(ChaoxingFailureCode.captchaRequired, '验证码加载失败，请重试');
  }
  final shadeImageUrl = chaoxingString(verification['shadeImage']);
  final cutoutImageUrl = chaoxingString(verification['cutoutImage']);
  if (shadeImageUrl.isEmpty || cutoutImageUrl.isEmpty) {
    throw const ChaoxingFailure(ChaoxingFailureCode.captchaRequired, '验证码加载失败，请重试');
  }
  return ChaoxingCaptchaPuzzle(
    token: chaoxingString(json['token'], fallback: token),
    iv: iv,
    shadeImageUrl: shadeImageUrl,
    cutoutImageUrl: cutoutImageUrl,
  );
}

// 拖动位置按底图的原始像素算，界面缩放要乘回去。
Future<ChaoxingCaptchaAnswer> chaoxingCaptchaVerify(
  ChaoxingClient client, {
  required ChaoxingCaptchaPuzzle puzzle,
  required double position,
  required Uri referer,
}) async {
  final response = await client.http.get(
    Uri.parse(chaoxingCaptchaResultUri).replace(
      queryParameters: {
        'captchaId': chaoxingCaptchaId,
        'type': chaoxingCaptchaType,
        'token': puzzle.token,
        'textClickArr': jsonEncode([
          {'x': position.round()},
        ]),
        'coordinate': '[]',
        'runEnv': '10',
        'version': chaoxingCaptchaVersion,
        't': 'a',
        'iv': puzzle.iv,
        '_': '${DateTime.now().millisecondsSinceEpoch}',
      },
    ),
    headers: {'Referer': referer.toString()},
  );
  final json = chaoxingJson(chaoxingJsonp(response.body));
  if (chaoxingInt(json['error']) == 1) {
    return ChaoxingCaptchaAnswer(passed: false, message: chaoxingString(json['msg'], fallback: '验证没有通过'));
  }
  if (json['result'] != true) return const ChaoxingCaptchaAnswer(passed: false);
  final extra = json['extraData'];
  final decoded = extra is Map ? extra.cast<String, Object?>() : chaoxingJson(chaoxingString(extra));
  final validate = chaoxingString(decoded['validate']);
  if (validate.isEmpty) return const ChaoxingCaptchaAnswer(passed: false, message: '验证没有通过');
  return ChaoxingCaptchaAnswer(passed: true, validate: validate);
}

Future<int> _chaoxingCaptchaConf(ChaoxingClient client, int now) async {
  final response = await client.http.get(
    Uri.parse(chaoxingCaptchaConfUri).replace(
      queryParameters: {'captchaId': chaoxingCaptchaId, '_': '$now'},
    ),
  );
  final t = chaoxingInt(chaoxingJson(chaoxingJsonp(response.body))['t']);
  if (t == 0) {
    throw const ChaoxingFailure(ChaoxingFailureCode.captchaRequired, '验证码加载失败，请重试');
  }
  return t;
}
