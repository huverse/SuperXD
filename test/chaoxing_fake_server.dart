import 'dart:async';
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
  }) async {
    final fake = FakeChaoxing._(
      uid: uid,
      puid: puid,
      fid: fid,
      name: name,
      encryptedPhone: await chaoxingEncrypt(phoneNumber),
      encryptedPassword: await chaoxingEncrypt(password),
    );
    fake.users[phoneNumber] = (phoneCipher: fake.encryptedPhone, passwordCipher: fake.encryptedPassword, name: name);
    return fake;
  }

  Future<void> addUser(String phoneNumber, String password, {String? name}) async {
    users[phoneNumber] = (
      phoneCipher: await chaoxingEncrypt(phoneNumber),
      passwordCipher: await chaoxingEncrypt(password),
      name: name ?? '同学$phoneNumber',
    );
  }

  final int uid;
  final int puid;
  final int fid;
  final String name;
  final String encryptedPhone;
  final String encryptedPassword;

  final calls = <String>[];
  String? loginBody;
  String? lastUserAgent;

  // 用户信息：带了设备信息时是 POST（data=RSA 密文），否则 GET；clientId 与多个学校单位按需给。
  String? userInfoMethod;
  String? userInfoBody;
  String? clientId;
  List<Map<String, Object?>> unitConfigInfos = [];

  // 设上时活动列表的响应卡在这里，测「刷新中」的中间状态；放行时 complete。
  Completer<void>? activityListGate;

  // 活动列表响应 data 级别的 ext（preSign 回传的是它）。
  Map<String, Object?> listExt = {'a': 1};

  // preSign 之后的 analysis → analysis2。
  String analysisPage = "var code='+'abc123ef'; ";
  String? analysis2Code;
  int preSignStatusCode = 200;

  // 学习通课表（kb.chaoxing.com），默认一节课都没有。
  Map<String, Object?> lessons = {
    'curriculum': {'lessonTimeConfigArray': <String>[], 'firstWeekDate': 0},
    'lessonArray': <Object?>[],
  };

  // 支持多个学习通账号：手机号 → 手机号密文、密码密文与昵称（代签要两个账号）。
  final users = <String, ({String phoneCipher, String passwordCipher, String name})>{};
  String? lastPhone;
  Map<String, String>? signQuery;
  String? preSignBody;

  List<Map<String, Object?>> courses = [];
  List<Map<String, Object?>> activities = [];
  Map<String, Object?> activeInfo = {};

  // 按活动号给不同的详情（签退跳转要取另一个活动）。
  Map<int, Map<String, Object?>> activeInfos = {};

  // 列进来的活动号，详情接口按读不到返回，用来验单条失败不影响其余。
  final failingActiveInfoIds = <int>{};
  String preSignHtml = '';
  String signResponse = 'success';

  // 按顺序取用的签到结果，取完回到 signResponse。
  final signResponses = <String>[];
  int? checkSignCodeResult = 1;
  Map<String, Object?> signDetail = {'isOver': 0};

  // 群聊：环信令牌、群列表与漫游消息。
  String imPasswordHex = '9523f40340818f573b71a58235f15865';
  String? imTokenBody;
  final imGroups = <Map<String, Object?>>[];
  final imMessages = <List<int>>[];
  // 与 imMessages 一一对应的发起时刻（毫秒）；没给的那条消息不带时间。
  final imTimestamps = <int?>[];
  String? imRoamingBody;
  String? imRoamingQueue;

  // 人脸识别：学习通里存着的人脸照片与换回来的 faceEnc。
  String profileFaceObjectId = 'face-object-1';
  // 云盘原图下载（p.cldisk.com）回的字节，任意 objectId 都给同一张 3:4 小图。
  List<int> facePhotoBytes = picture.encodeJpg(picture.Image(width: 12, height: 16));
  String faceEnc = 'FACE-ENC';
  Map<String, String>? faceQuery;

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
    lastUserAgent = request.headers['User-Agent'] ?? request.headers['user-agent'];
    final path = request.url.path;
    if (request.url.host == 'passport2.chaoxing.com' && path == '/fanyalogin') {
      loginBody = request.body;
      final fields = Uri.splitQueryString(request.body);
      final matched = users.entries.where((entry) => entry.value.phoneCipher == fields['uname']).firstOrNull;
      if (matched == null || matched.value.passwordCipher != fields['password']) {
        return _json({'status': false, 'msg2': '用户名或密码错误'});
      }
      lastPhone = matched.key;
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
      userInfoMethod = request.method;
      userInfoBody = request.body;
      final phone = lastPhone ?? users.keys.first;
      return _json({
        'msg': {
          'uid': uid,
          'puid': puid,
          'fid': fid,
          'name': users[phone]?.name ?? name,
          'uname': phone,
          'pic': 'http://p.ananas.chaoxing.com/star3/photo.jpg',
          'schoolname': '示例大学',
          'clientId': ?clientId,
          'unitConfigInfos': unitConfigInfos,
          'accountInfo': {
            'imAccount': {'password': imPasswordHex},
          },
        },
      });
    }
    if (request.url.host == 'mooc1-api.chaoxing.com') {
      // 真实的课程频道都带 cataName；测试夹具里省掉，这里统一补上。
      return _json({
        'result': 1,
        'channelList': [for (final course in courses) {'cataName': '课程', ...course}],
      });
    }
    if (request.url.host == 'kb.chaoxing.com') {
      return _json({'data': lessons});
    }
    if (request.url.host == 'p.cldisk.com') {
      // 尺寸要不小于 16：人脸照片的重处理（随机裁剪旋转）对更小的图会按「照片读取失败」拒绝。
      return _image(picture.encodePng(picture.Image(width: 64, height: 64)));
    }
    if (request.url.host == 'mobilelearn.chaoxing.com') {
      switch (path) {
        case '/v2/apis/active/student/activelist':
          await activityListGate?.future;
          return _json({'data': {'activeList': activities, 'ext': listExt}});
        case '/v2/apis/active/getPPTActiveInfo':
          final activeId = int.tryParse(request.url.queryParameters['activeId'] ?? '');
          if (activeId != null && failingActiveInfoIds.contains(activeId)) return _json({'result': 0});
          return _json({'data': activeInfos[activeId] ?? activeInfo});
        case '/newsign/signDetail':
          return _json(signDetail);
        case '/v2/apis/sign/collectionfilephotoEnc':
          return _json({'data': {'oldObjectId': profileFaceObjectId}});
        case '/pptSign/check-face-result':
          faceQuery = request.url.queryParameters;
          return _json({'enc': faceEnc});
        case '/newsign/preSign':
          preSignBody = request.body;
          if (preSignStatusCode != 200) return http.Response('', preSignStatusCode);
          return _text(preSignHtml);
        case '/pptSign/analysis':
          return _text(analysisPage);
        case '/pptSign/analysis2':
          analysis2Code = request.url.queryParameters['code'];
          return _text('');
        case '/pptSign/stuSignajax':
          signQuery = request.url.queryParameters;
          return _text(signResponses.isEmpty ? signResponse : signResponses.removeAt(0), type: 'text/plain');
        case '/widget/sign/pcStuSignController/checkSignCode':
          return _json({'result': checkSignCodeResult});
      }
    }
    if (request.url.host == 'a1-vip6.easemob.com' || request.url.host == 'a1-vip6.easecdn.com') {
      if (path.endsWith('/token')) {
        imTokenBody = request.body;
        final fields = jsonDecode(request.body) as Map;
        if (fields['grant_type'] != 'password' || '${fields['username']}'.isEmpty) {
          return _json({'error': 'invalid_grant'});
        }
        return _json({
          'access_token': 'im-token',
          'user': {'uuid': 'im-uuid', 'username': 'cx_${fields['username']}'},
        });
      }
      if (path.endsWith('/joined_chatgroups')) {
        return _json({'data': imGroups});
      }
      if (path.endsWith('/messageroaming')) {
        imRoamingBody = request.body;
        imRoamingQueue = '${(jsonDecode(request.body) as Map)['queue']}';
        return _json({
          'data': {
            'msgs': [
              for (var index = 0; index < imMessages.length; index++)
                {
                  'msg': base64.encode(imMessages[index]),
                  if (index < imTimestamps.length && imTimestamps[index] != null) 'timestamp': imTimestamps[index],
                },
            ],
          },
        });
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
    // 学习通云盘的原图下载：人脸照片预览与保存到本机走这里。
    if (request.url.host == 'p.cldisk.com') {
      return http.Response.bytes(facePhotoBytes, 200, headers: {'content-type': 'image/jpeg'});
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
