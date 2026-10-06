import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as picture;

import 'package:superxd/toolbox/chaoxing/chaoxing_crypto.dart';

// 内存版学习通服务：按协议规则校验登录、回课程与活动、按脚本给 preSign 页面与签到结果，
// 供协议层测试走完整链路（真实接口的验证只在授权账号上做）。
class FakeChaoxing {
  FakeChaoxing._({
    required this.uid,
    required this.puid,
    required this.fid,
    required this.name,
    required this.encryptedPhone,
    required this.encryptedPassword,
  });

  static Future<FakeChaoxing> create({
    String phoneNumber = '13800138000',
    String password = 'myPassword123',
    int uid = 777,
    int puid = 7007,
    int fid = 1234,
    String name = '同学甲',
  }) async => FakeChaoxing._(
    uid: uid,
    puid: puid,
    fid: fid,
    name: name,
    encryptedPhone: await chaoxingEncrypt(phoneNumber),
    encryptedPassword: await chaoxingEncrypt(password),
  );

  final int uid;
  final int puid;
  final int fid;
  final String name;
  final String encryptedPhone;
  final String encryptedPassword;

  final calls = <String>[];
  String? loginBody;
  Map<String, String>? signQuery;
  String? preSignBody;

  List<Map<String, Object?>> courses = [];
  List<Map<String, Object?>> activities = [];
  Map<String, Object?> activeInfo = {};

  // 按活动号给不同的详情（签退跳转要取另一个活动）。
  Map<int, Map<String, Object?>> activeInfos = {};
  String preSignHtml = '';
  String signResponse = 'success';

  // 按顺序取用的签到结果，取完回到 signResponse。
  final signResponses = <String>[];
  int? checkSignCodeResult = 1;
  Map<String, Object?> signDetail = {'isOver': 0};

  // 云盘（拍照签到）。
  String? uploadQuery;
  String? uploadContentType;
  String? uploadBody;

  // 滑块验证码。
  String captchaTime = '1700000000000';
  String captchaToken = 'captcha-image-token';
  String captchaValidate = 'captcha-validate';
  bool captchaPassed = true;
  int captchaError = 0;
  String? captchaResultQuery;
  String? captchaImageQuery;
  String? captchaReferer;
  final captchaCalls = <String>[];

  // 不带 charset 时 http.Response 按 latin1 编码，中文会乱码。
  static http.Response _json(Object value) => http.Response(
    jsonEncode(value),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  static http.Response _text(String body, {String type = 'text/html'}) => http.Response(
    body,
    200,
    headers: {'content-type': '$type; charset=utf-8'},
  );

  // 验证码三个接口都是 JSONP。
  static http.Response _jsonp(Object value) => _text('cx_captcha_function(${jsonEncode(value)})', type: 'application/javascript');

  static http.Response _image(Uint8List bytes) => http.Response.bytes(
    bytes,
    200,
    headers: {'content-type': 'image/png'},
  );

  http.Client client() => MockClient((request) async {
    calls.add('${request.method} ${request.url.host}${request.url.path}');
    final path = request.url.path;
    if (request.url.host == 'passport2.chaoxing.com' && path == '/fanyalogin') {
      loginBody = request.body;
      final fields = Uri.splitQueryString(request.body);
      if (fields['uname'] != encryptedPhone || fields['password'] != encryptedPassword) {
        return _json({'status': false, 'msg2': '用户名或密码错误'});
      }
      return http.Response(
        jsonEncode({'status': true}),
        200,
        headers: {
          'content-type': 'application/json; charset=utf-8',
          'set-cookie': '_uid=$uid; Path=/, fid=$fid; Path=/',
        },
      );
    }
    if (request.url.host == 'sso.chaoxing.com') {
      return _json({
        'msg': {
          'uid': uid,
          'puid': puid,
          'fid': fid,
          'name': name,
          'uname': '13800138000',
          'pic': 'http://p.ananas.chaoxing.com/star3/photo.jpg',
          'schoolname': '示例大学',
          'accountInfo': {
            'imAccount': {'password': 'im-cipher'},
          },
        },
      });
    }
    if (request.url.host == 'mooc1-api.chaoxing.com') {
      return _json({'result': 1, 'channelList': courses});
    }
    if (request.url.host == 'mobilelearn.chaoxing.com') {
      switch (path) {
        case '/v2/apis/active/student/activelist':
          return _json({'data': {'activeList': activities}});
        case '/v2/apis/active/getPPTActiveInfo':
          final activeId = int.tryParse(request.url.queryParameters['activeId'] ?? '');
          return _json({'data': activeInfos[activeId] ?? activeInfo});
        case '/newsign/signDetail':
          return _json(signDetail);
        case '/newsign/preSign':
          preSignBody = request.body;
          return _text(preSignHtml);
        case '/pptSign/stuSignajax':
          signQuery = request.url.queryParameters;
          return _text(signResponses.isEmpty ? signResponse : signResponses.removeAt(0), type: 'text/plain');
        case '/widget/sign/pcStuSignController/checkSignCode':
          return _json({'result': checkSignCodeResult});
      }
    }
    if (request.url.host == 'pan-yz.chaoxing.com') {
      if (path == '/api/token/uservalid') return _json({'_token': 'cloud-token'});
      if (path == '/upload') {
        uploadQuery = request.url.query;
        uploadContentType = request.headers['content-type'];
        uploadBody = String.fromCharCodes(request.bodyBytes);
        return _json({'objectId': 'obj-1'});
      }
    }
    if (request.url.host == 'captcha.chaoxing.com') {
      captchaCalls.add(path);
      switch (path) {
        case '/captcha/get/conf':
          return _jsonp({'t': captchaTime});
        case '/captcha/get/verification/image':
          captchaImageQuery = request.url.query;
          return _jsonp({
            'token': captchaToken,
            'imageVerificationVo': {
              'shadeImage': 'https://captcha.chaoxing.com/captcha/shade.png',
              'cutoutImage': 'https://captcha.chaoxing.com/captcha/cutout.png',
            },
          });
        case '/captcha/shade.png':
          return _image(picture.encodePng(picture.Image(width: 280, height: 160)));
        case '/captcha/cutout.png':
          return _image(picture.encodePng(picture.Image(width: 56, height: 160)));
        case '/captcha/check/verification/result':
          captchaResultQuery = request.url.query;
          captchaReferer = request.headers['referer'] ?? request.headers['Referer'];
          if (captchaError == 1) return _jsonp({'error': 1, 'msg': '验证码已失效'});
          if (!captchaPassed) return _jsonp({'result': false});
          return _jsonp({'result': true, 'extraData': jsonEncode({'validate': captchaValidate})});
      }
    }
    return http.Response('not found', 404);
  });
}
