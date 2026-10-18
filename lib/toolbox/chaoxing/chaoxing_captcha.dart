import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import 'package:superxd/toolbox/chaoxing/chaoxing_client.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_crypto.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_http.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_photo.dart';

// 学习通的滑块验证码：先取底图与缺口图，用户拖到位后换一次性的 validate，随签到提交回去。
// 三个接口都是 JSONP，响应外面裹着 cx_captcha_function(...)；都要带 callback，不带时对方只回 {"10013":"CALLBACK ERROR"}
// （2026-10-18 实测，以前取配置与提交校验两处漏了，验证码一出现就加载失败或永远「没有对齐」）。
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
    throw const ChaoxingFailure(ChaoxingFailureCode.captchaRequired, chaoxingCaptchaLoadFailedMessage);
  }
  final shadeImageUrl = chaoxingString(verification['shadeImage']);
  final cutoutImageUrl = chaoxingString(verification['cutoutImage']);
  if (shadeImageUrl.isEmpty || cutoutImageUrl.isEmpty) {
    throw const ChaoxingFailure(ChaoxingFailureCode.captchaRequired, chaoxingCaptchaLoadFailedMessage);
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
        'callback': 'cx_captcha_function',
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
      queryParameters: {'callback': 'cx_captcha_function', 'captchaId': chaoxingCaptchaId, '_': '$now'},
    ),
  );
  final t = chaoxingInt(chaoxingJson(chaoxingJsonp(response.body))['t']);
  if (t == 0) {
    throw const ChaoxingFailure(ChaoxingFailureCode.captchaRequired, chaoxingCaptchaLoadFailedMessage);
  }
  return t;
}

// [人工决策-2026-10-18 13:07:53] 滑块验证码先自动试一次，没过或认不准才弹手动滑块（用户选定，同参考项目的流程）；
// 找缺口自写、不用模型：参考项目用的是第三方贡献的检测模型，没有单独许可、作者也不欢迎二次分发，不引入。
// 做法：底图上有真缺口与一个形状不同的诱饵，真缺口里盖的是同一块原图，只是整体调亮或调暗了一层，缺口块里装的正是这块原图。
// 缺口块已经放在正确的高度上，只需横向逐列比对：取缺口块内部（去掉描边）的像素，与底图同位置算归一化相关，
// 整体调亮调暗不影响它；诱饵下面是别处的画面，对不上。2026-10-18 用真实题目验证：离线 30 张看图全对，提交校验 16 次全过。
const _captchaMaskInset = 4;

// 相关系数低于它就当认不准，直接交给手动（真实题目里正确位置最低约 0.77，平坦的草地、墙面分数偏低）。
const chaoxingCaptchaMinScore = 0.6;

// 缺口块在底图上的横向偏移（底图像素）与那里的相关系数；图片解不开或尺寸不对时返回空。
({int offset, double score})? chaoxingCaptchaMatch(Uint8List shadeBytes, Uint8List cutoutBytes) {
  final shade = decodeChaoxingPhoto(shadeBytes);
  final cutout = decodeChaoxingPhoto(cutoutBytes);
  if (shade == null || cutout == null || shade.height != cutout.height || cutout.width >= shade.width) return null;
  final width = cutout.width;
  final height = cutout.height;
  final opaque = [for (var y = 0; y < height; y++) [for (var x = 0; x < width; x++) cutout.getPixel(x, y).a >= cutout.maxChannelValue]];
  bool inside(int x, int y) {
    for (var dy = -_captchaMaskInset; dy <= _captchaMaskInset; dy++) {
      for (var dx = -_captchaMaskInset; dx <= _captchaMaskInset; dx++) {
        final nx = x + dx;
        final ny = y + dy;
        if (nx < 0 || ny < 0 || nx >= width || ny >= height || !opaque[ny][nx]) return false;
      }
    }
    return true;
  }

  final points = [for (var y = 0; y < height; y++) for (var x = 0; x < width; x++) if (inside(x, y)) (x, y)];
  if (points.length < 100) return null;
  // 三个通道并在一起当样本：调亮调暗对三个通道是同一个线性变换，相关性不受影响，比只看灰度分得更开。
  final piece = <double>[];
  for (final (x, y) in points) {
    final pixel = cutout.getPixel(x, y);
    piece..add(pixel.r.toDouble())..add(pixel.g.toDouble())..add(pixel.b.toDouble());
  }
  final count = piece.length;
  final pieceMean = piece.reduce((sum, value) => sum + value) / count;
  final centered = [for (final value in piece) value - pieceMean];
  final pieceNorm = centered.fold(0.0, (sum, value) => sum + value * value);
  if (pieceNorm == 0) return null;
  var best = (offset: 0, score: -1.0);
  for (var offset = 0; offset <= shade.width - width; offset++) {
    var sum = 0.0;
    var squares = 0.0;
    var product = 0.0;
    var index = 0;
    for (final (x, y) in points) {
      final pixel = shade.getPixel(offset + x, y);
      for (final value in [pixel.r.toDouble(), pixel.g.toDouble(), pixel.b.toDouble()]) {
        sum += value;
        squares += value * value;
        product += centered[index++] * value;
      }
    }
    final variance = squares - sum * sum / count;
    final score = variance <= 0 ? 0.0 : product / sqrt(pieceNorm * variance);
    if (score > best.score) best = (offset: offset, score: score);
  }
  return best;
}

// 自动识别要提交的坐标；认不准时返回空。参数打包成一个，方便丢进后台 isolate（compute）。
// 提交口径是缺口块偏移减 2（参考项目自动识别按缺口框左缘减 4，框比缺口块图左缘多 2），2026-10-18 实测 8 次全过；
// 手动滑块按拖动比例换算（chaoxingCaptchaPosition），两种口径对方都认，靠右时差几个像素在容差内（同日实测 8 次全过）。
double? chaoxingCaptchaAutoPosition(({Uint8List shade, Uint8List cutout}) images) {
  final match = chaoxingCaptchaMatch(images.shade, images.cutout);
  return match == null || match.score < chaoxingCaptchaMinScore ? null : match.offset - 2.0;
}
