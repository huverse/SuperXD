import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as picture;

import 'package:superxd/toolbox/chaoxing/chaoxing_activity.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_captcha.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_client.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_crypto.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_device.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_face.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_http.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_lessons.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_location.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_photo.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_qrcode.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_signer.dart';

import 'chaoxing_fake_server.dart';

class _FakeProbe implements ChaoxingDeviceProbe {
  _FakeProbe({this.oaidValue = ''});
  final String oaidValue;

  @override
  Future<ChaoxingDeviceFacts> facts(String packageName) async => const ChaoxingDeviceFacts(
    androidId: 'android-1',
    fingerprint: 'fp/1',
    mediaDrmId: 'drm',
    osVersion: '14',
    language: 'zh-CN',
    brand: 'brand',
    board: 'board',
    hardware: 'hw',
    model: 'model',
    abis: 'arm64-v8a',
    width: 1080,
    height: 2400,
    density: '3.0',
  );

  @override
  Future<String> oaid() async => oaidValue;
}

const _account = ChaoxingAccount(
  phoneNumber: '13800138000',
  uid: 777,
  puid: 7007,
  fid: 1234,
  name: '同学甲',
  deviceCode: 'device-code',
);

ChaoxingActivity _activity(
  ChaoxingSignType signType, {
  int activeId = 501,
  String ext = '{"a":1}',
}) => ChaoxingActivity(
  activeId: activeId,
  courseId: 9001,
  classId: 88,
  title: '签到',
  subtitle: '高等数学',
  signType: signType,
  startTime: DateTime.fromMillisecondsSinceEpoch(1760000000000, isUtc: true),
  status: 1,
  userStatus: 0,
  ext: ext,
);

void main() {
  test('登录密文与 openssl 的已知答案一致', () async {
    // key 与 IV 同为固定串 u2oh6Vu^HWe4_AES，AES-128-CBC + PKCS7 后 Base64。
    expect(await chaoxingEncrypt('13800138000'), 'yYcVatS+4J+JGnm88UM56A==');
    expect(await chaoxingEncrypt('myPassword123'), '+OczAQyN4UvcQnaBl6V29Q==');
  });

  test('登录表单按表单编码提交，密文里的加号不串位', () {
    expect(
      chaoxingLoginBody(
        encryptedPhone: 'yYcVatS+4J+JGnm88UM56A==',
        encryptedPassword: '+OczAQyN4UvcQnaBl6V29Q==',
      ),
      'fid=-1&uname=yYcVatS%2B4J%2BJGnm88UM56A%3D%3D'
      '&password=%2BOczAQyN4UvcQnaBl6V29Q%3D%3D'
      '&refer=https%3A%2F%2Fi.chaoxing.com&t=true&forbidotherlogin=0'
      '&validate=&doubleFactorLogin=0&independentId=0&independentNameId=0',
    );
    expect(chaoxingFormBody({'ext': '{"a":1}'}), 'ext=%7B%22a%22%3A1%7D');
  });

  test('设备码形状稳定', () {
    final code = chaoxingDeviceCode(Random(7));
    expect(code, chaoxingDeviceCode(Random(7)));
    expect(code.length, 88);
  });

  test('Cookie 会话：登录整体覆盖，用户信息按名合并，其他域各存各的', () {
    final jar = ChaoxingCookieJar();
    jar.save(Uri.parse('https://passport2.chaoxing.com/fanyalogin'), {'_uid': '1', 'fid': '10'});
    expect(jar.load(Uri.parse('https://mobilelearn.chaoxing.com/x')), {'_uid': '1', 'fid': '10'});
    jar.save(Uri.parse('https://passport2.chaoxing.com/apis/login/userLogin4Uname.do'), {'fid': '20'});
    expect(jar.load(Uri.parse('https://mobilelearn.chaoxing.com/x')), {'_uid': '1', 'fid': '20'});
    // chaoxing.com 的各个子域共用同一份会话 Cookie。
    expect(jar.load(Uri.parse('https://pan-yz.chaoxing.com/x')), {'_uid': '1', 'fid': '20'});
    jar.save(Uri.parse('https://p.cldisk.com/x'), {'only': 'y'});
    expect(jar.load(Uri.parse('https://p.cldisk.com/x')), {'only': 'y'});
    jar.save(Uri.parse('https://passport2.chaoxing.com/fanyalogin'), {'_uid': '9'});
    expect(jar.session, {'_uid': '9'});
    expect(jar.load(Uri.parse('https://p.cldisk.com/x')), {'only': 'y'});
  });

  test('preSign 页面状态判定', () {
    expect(chaoxingPreSignStatus('<script>signstatus = 0;</script>'), ChaoxingPreSignStatus.readyToSign);
    expect(chaoxingPreSignStatus('<script>signstatus = 1;</script>'), ChaoxingPreSignStatus.alreadySigned);
    expect(
      chaoxingPreSignStatus('{"primaryAttend":{"id":1,"status":9}}'),
      ChaoxingPreSignStatus.alreadySigned,
    );
    expect(chaoxingPreSignStatus('{"primaryAttend":{"status":0}}'), ChaoxingPreSignStatus.readyToSign);
    expect(chaoxingPreSignStatus('同学，下次早点哦'), ChaoxingPreSignStatus.expired);
    expect(
      () => chaoxingPreSignStatus('校验失败，未查询到活动数据'),
      throwsA(isA<ChaoxingFailure>().having((failure) => failure.code, 'code', ChaoxingFailureCode.noPermission)),
    );
  });

  test('提交响应的分支', () {
    expect(chaoxingSignOutcome('success'), isA<ChaoxingSignSucceeded>());
    // success2 是「迟到或签到已结束」，按失败处理（与学习通客户端一致）。
    expect(
      () => chaoxingSignOutcome('success2'),
      throwsA(isA<ChaoxingFailure>().having((failure) => failure.message, 'message', '迟到或签到已结束')),
    );
    expect(
      chaoxingSignOutcome('validate_enc2value'),
      isA<ChaoxingSignNeedsCaptcha>().having((value) => value.enc2, 'enc2', 'enc2value'),
    );
    for (final (body, code) in [
      ('您已签到过了', ChaoxingFailureCode.alreadySigned),
      ('签到失败，请重新扫描。', ChaoxingFailureCode.qrCodeExpired),
      ('errorLocation_123.4', ChaoxingFailureCode.wrongPosition),
      ('checkFace_abc', ChaoxingFailureCode.faceCheck),
      ('[face]未检测到人脸', ChaoxingFailureCode.faceRequired),
      ('未知回复', ChaoxingFailureCode.server),
    ]) {
      expect(
        () => chaoxingSignOutcome(body),
        throwsA(isA<ChaoxingFailure>().having((failure) => failure.code, 'code', code)),
        reason: body,
      );
    }
    expect(
      () => chaoxingSignOutcome('errorLocation_123.4'),
      throwsA(isA<ChaoxingFailure>().having((failure) => failure.payload, 'payload', '123.4')),
    );
  });

  test('各签到类型的提交参数', () {
    const location = ChaoxingLocation(latitude: 39.915, longitude: 116.404, address: '教学楼');

    final locationQuery = chaoxingSignRequestUri(
      account: _account,
      submission: ChaoxingSignSubmission(
        activity: _activity(ChaoxingSignType.location),
        location: location,
      ),
    ).queryParameters;
    expect(locationQuery['address'], '教学楼');
    expect(locationQuery['ifTiJiao'], '1');
    // 提交的坐标是换算后加了随机偏移的值，落在原点的偏移范围内。
    expect((double.parse(locationQuery['latitude']!) - 39.915).abs(), lessThanOrEqualTo(chaoxingLocationRange));
    expect(locationQuery['deviceCode'], 'device-code');
    expect(locationQuery.containsKey('location'), isFalse);
    expect(jsonDecode(locationQuery['locationResult']!) as Map, contains('mockData'));

    final passwordQuery = chaoxingSignRequestUri(
      account: _account,
      submission: ChaoxingSignSubmission(
        activity: _activity(ChaoxingSignType.password),
        signCode: '1234',
      ),
    ).queryParameters;
    expect(passwordQuery['signCode'], '1234');
    expect(passwordQuery['latitude'], '-1');
    expect(passwordQuery.containsKey('location'), isFalse);
    // 签到码与手势不带 vp 两项，位置与二维码才带。
    expect(passwordQuery.containsKey('vpProbability'), isFalse);
    expect(locationQuery['vpProbability'], '-1');

    final gestureQuery = chaoxingSignRequestUri(
      account: _account,
      submission: ChaoxingSignSubmission(
        activity: _activity(ChaoxingSignType.gesture),
        signCode: '1235789',
        location: location,
      ),
    ).queryParameters;
    expect(gestureQuery['signCode'], '1235789');
    expect((double.parse(gestureQuery['latitude']!) - 39.915).abs(), lessThanOrEqualTo(chaoxingLocationRange));
    expect(jsonDecode(gestureQuery['location']!) as Map, isNot(contains('mockData')));

    final qrQuery = chaoxingSignRequestUri(
      account: _account,
      submission: ChaoxingSignSubmission(activity: _activity(ChaoxingSignType.qrCode), enc: 'ENCVALUE', location: location),
    ).queryParameters;
    expect(qrQuery['enc'], 'ENCVALUE');
    // 二维码的坐标参数固定 -1，位置只放在 location 与 locationResult 里。
    expect(qrQuery['latitude'], '-1');
    expect(qrQuery['longitude'], '-1');
    expect(jsonDecode(qrQuery['location']!) as Map, isNot(contains('mockData')));
    expect(jsonDecode(qrQuery['locationResult']!) as Map, contains('mockData'));
    expect(qrQuery['vpProbability'], '-1');

    // 人脸参数只有位置与二维码签到才带。
    final faceQr = chaoxingSignRequestUri(
      account: _account,
      submission: ChaoxingSignSubmission(activity: _activity(ChaoxingSignType.qrCode), enc: 'E', faceObjectId: 'face-1', faceEnc: 'FE'),
    ).queryParameters;
    expect(faceQr['currentFaceId'], 'face-1');
    expect(faceQr['faceEnc'], 'FE');
    expect(faceQr['ifCFP'], '0');
    final facePassword = chaoxingSignRequestUri(
      account: _account,
      submission: ChaoxingSignSubmission(activity: _activity(ChaoxingSignType.password), signCode: '1', faceObjectId: 'face-1'),
    ).queryParameters;
    expect(facePassword.containsKey('currentFaceId'), isFalse);

    final photoQuery = chaoxingSignRequestUri(
      account: _account,
      submission: ChaoxingSignSubmission(activity: _activity(ChaoxingSignType.photo), objectId: 'obj-1'),
    ).queryParameters;
    expect(photoQuery['objectId'], 'obj-1');
    expect(photoQuery['useragent'], '');
    expect(
      chaoxingSignRequestUri(
        account: _account,
        submission: ChaoxingSignSubmission(activity: _activity(ChaoxingSignType.photo)),
      ).queryParameters.containsKey('objectId'),
      isFalse,
    );

    final captchaQuery = chaoxingSignRequestUri(
      account: _account,
      submission: ChaoxingSignSubmission(
        activity: _activity(ChaoxingSignType.password),
        signCode: '1234',
        captchaValidate: 'valid-1',
        enc2: 'enc-two',
      ),
    ).queryParameters;
    expect(captchaQuery['validate'], 'valid-1');
    expect(captchaQuery['enc2'], 'enc-two');
  });

  test('缺参数的签到直接报输入错误，不发请求', () {
    expect(
      () => chaoxingSignRequestUri(
        account: _account,
        submission: ChaoxingSignSubmission(activity: _activity(ChaoxingSignType.location)),
      ),
      throwsA(isA<ChaoxingFailure>().having((failure) => failure.code, 'code', ChaoxingFailureCode.invalidInput)),
    );
  });

  test('坐标转换与公开实现一致', () {
    final toGcj = wgs84ToGcj02(39.915, 116.404);
    expect(toGcj.longitude, closeTo(116.41024449916938, 1e-9));
    expect(toGcj.latitude, closeTo(39.91640428150164, 1e-9));
    final toBd = gcj02ToBd09(39.915, 116.404);
    expect(toBd.longitude, closeTo(116.41036949371029, 1e-9));
    expect(toBd.latitude, closeTo(39.92133699351021, 1e-9));
    final backToGcj = bd09ToGcj02(39.915, 116.404);
    expect(backToGcj.longitude, closeTo(116.39762729119315, 1e-9));
    expect(backToGcj.latitude, closeTo(39.90865673957631, 1e-9));
    final backToWgs = gcj02ToWgs84(39.915, 116.404);
    expect(backToWgs.longitude, closeTo(116.39775550083061, 1e-9));
    expect(backToWgs.latitude, closeTo(39.91359571849836, 1e-9));

    final fromWgs = toBd09(39.915, 116.404, ChaoxingCoordinateSystem.wgs84);
    expect(fromWgs.longitude, closeTo(116.41662724378733, 1e-9));
    expect(fromWgs.latitude, closeTo(39.922699552216216, 1e-9));
  });

  test('位置坐标先换算成 BD-09 再随机偏移，超范围时收紧重试', () {
    // 地图给的是高德的 GCJ-02 坐标，收藏里两种坐标系都可能存着。
    const picked = ChaoxingLocation(latitude: 36.6, longitude: 117.0, address: '知敬楼402', system: ChaoxingCoordinateSystem.gcj02);
    final bd09 = gcj02ToBd09(36.6, 117.0);
    final query = chaoxingSignRequestUri(
      account: _account,
      submission: ChaoxingSignSubmission(activity: _activity(ChaoxingSignType.location), location: picked),
    ).queryParameters;
    final latitude = double.parse(query['latitude']!);
    final longitude = double.parse(query['longitude']!);
    expect((latitude - bd09.latitude).abs(), lessThanOrEqualTo(chaoxingLocationRange));
    expect((longitude - bd09.longitude).abs(), lessThanOrEqualTo(chaoxingLocationRange));
    expect((latitude - 36.6).abs(), greaterThan(0.001));
    expect(query['address'], '知敬楼402');
    // latitude 参数是原值，locationResult 里的是保留 6 位小数的同一个点（与学习通客户端一致）。
    expect(jsonDecode(query['locationResult']!)['latitude'], closeTo(latitude, 1e-6));

    final tight = chaoxingSignRequestUri(
      account: _account,
      submission: ChaoxingSignSubmission(activity: _activity(ChaoxingSignType.location), location: picked, tightenLocation: true),
    ).queryParameters;
    expect((double.parse(tight['latitude']!) - bd09.latitude).abs(), lessThanOrEqualTo(chaoxingLocationTightRange));
  });

  test('位置偏移落在设定范围内且不带偏移时原样提交', () {
    const location = ChaoxingLocation(latitude: 39.915, longitude: 116.404, address: '教学楼');
    final random = Random(3);
    for (var index = 0; index < 50; index++) {
      final shuffled = location.randomized(random: random);
      expect((shuffled.latitude - 39.915).abs(), lessThanOrEqualTo(0.00005));
      expect((shuffled.longitude - 116.404).abs(), lessThanOrEqualTo(0.00005));
    }
    final tightened = location.randomized(range: 0.00001, random: Random(3));
    expect((tightened.latitude - 39.915).abs(), lessThanOrEqualTo(0.00001));
    expect(jsonDecode(location.payload(mock: false)) as Map, isNot(contains('mockData')));
  });

  test('列表只收签到类活动，认不出的类型保留为 unknown 待详情补认', () {
    final course = const ChaoxingCourse(courseId: 9001, classId: 88, name: '高等数学');
    final parsed = [
      {'id': 1, 'type': 2, 'otherId': '4', 'nameOne': '签到', 'nameFour': '高等数学', 'startTime': 1760000000000, 'ext': {'a': 1}},
      {'id': 2, 'type': 74, 'otherId': '5', 'nameOne': '签到码', 'startTime': 1760000000000},
      {'id': 3, 'type': 3, 'otherId': '4', 'nameOne': '作业', 'startTime': 1760000000000},
      {'id': 4, 'type': 2, 'otherId': '9', 'nameOne': '未知类型', 'startTime': 1760000000000},
      {'id': 0, 'type': 2, 'otherId': '4', 'nameOne': '缺 id', 'startTime': 1760000000000},
    ].map((json) => chaoxingActivity(json.cast<String, Object?>(), course, ext: '{"a":1}')).toList();
    // 非签到频道（type 3 是作业）与缺 id 的不入列；otherId 认不出的保留（unknown），点开时详情补认。
    expect(parsed.whereType<ChaoxingActivity>().map((activity) => activity.activeId), [1, 2, 4]);
    expect(parsed[3]!.signType, ChaoxingSignType.unknown);
    expect(parsed.first!.ext, '{"a":1}');
    expect(parsed.first!.subtitle, '高等数学');
    expect(parsed.first!.startTime.millisecondsSinceEpoch, 1760000000000);
  });

  test('活动详情：签退状态与位置范围', () {
    expect(
      chaoxingActiveInfoFrom({'signInId': 0, 'signOutId': 0, 'signOutPublishTimeStamp': 4999}).signOutState,
      ChaoxingSignOutState.none,
    );
    expect(
      chaoxingActiveInfoFrom({'signInId': 502}).signOutState,
      ChaoxingSignOutState.signOutActivity,
    );
    expect(
      chaoxingActiveInfoFrom({'signInId': 0, 'signOutId': 503, 'signOutPublishTimeStamp': 1760000000000}).signOutState,
      ChaoxingSignOutState.signOutPublished,
    );
    expect(
      chaoxingActiveInfoFrom({'signInId': 0, 'signOutPublishTimeStamp': 1760000000000}).signOutState,
      ChaoxingSignOutState.signOutPending,
    );
    final info = chaoxingActiveInfoFrom({
      'ifNeedVCode': 1,
      'openCheckFaceFlag': 1,
      'ifopenAddress': 1,
      'ifrefreshewm': 1,
      'numberCount': 4,
      'locationRange': 300,
      'locationLatitude': '39.915',
      'locationLongitude': 116.404,
    });
    expect(info.needCaptcha, isTrue);
    expect(info.needFace, isTrue);
    expect(info.needLocation, isTrue);
    expect(info.refreshQrCode, isTrue);
    expect(info.signCodeLength, 4);
    expect(info.locationRange, 300);
    expect(info.locationLatitude, 39.915);
    expect(info.locationLongitude, 116.404);
  });

  test('端到端：登录、课程、活动、preSign 与签到', () async {
    final fake = await FakeChaoxing.create();
    fake.courses = [
      {
        'content': {
          'id': 88,
          'course': {
            'data': [
              {'id': 9001, 'name': '高等数学', 'teacherfactor': '张老师', 'imageurl': 'https://x/c.jpg'},
            ],
          },
        },
      },
    ];
    fake.activities = [
      {'id': 501, 'type': 2, 'otherId': '5', 'nameOne': '签到', 'nameFour': '高等数学', 'startTime': 1760000000000, 'status': 1, 'userStatus': 0, 'ext': {'a': 1}},
    ];
    fake.activeInfo = {'numberCount': 4, 'signOutPublishTimeStamp': 4999};
    final http = ChaoxingHttp(client: fake.client());
    final client = await ChaoxingClient.signIn(
      http: http,
      phoneNumber: '13800138000',
      password: 'myPassword123',
    );
    expect(client.account!.name, '同学甲');
    expect(client.account!.puid, 7007);
    expect(client.account!.schoolName, '示例大学');
    expect(client.account!.photoUrl, 'https://p.ananas.chaoxing.com/star3/photo.jpg');
    expect(fake.loginBody, contains('uname=yYcVatS%2B4J%2BJGnm88UM56A%3D%3D'));

    final courses = await chaoxingCourses(client);
    expect(courses.single.name, '高等数学');
    expect(courses.single.classId, 88);

    final activities = await chaoxingActivities(client, courses.single);
    expect(activities.single.activeId, 501);

    final info = await chaoxingActiveInfo(client, activities.single.activeId);
    expect(info.signCodeLength, 4);
    expect(info.signOutState, ChaoxingSignOutState.none);

    fake.preSignHtml = '<script>signstatus = 0;</script>';
    fake.listExt = {'list': 'ext'};
    final relisted = await chaoxingActivities(client, courses.single);
    expect(await chaoxingPreSign(client, relisted.single), ChaoxingPreSignStatus.readyToSign);
    // preSign 回传的是活动列表 data 级别的 ext，不是每条活动自己的字段。
    expect(jsonDecode(Uri.splitQueryString(fake.preSignBody!)['ext']!), {'list': 'ext'});
    // preSign 之后紧跟 analysis → analysis2，把页面里的 code 原样带过去。
    expect(fake.analysis2Code, 'abc123ef');

    fake.signResponse = 'success';
    final result = await chaoxingSubmit(
      client,
      ChaoxingSignSubmission(activity: activities.single, signCode: '1234'),
    );
    expect(result.late, isFalse);
    expect(fake.signQuery!['activeId'], '501');
    expect(fake.signQuery!['uid'], '7007');
    expect(fake.signQuery!['fid'], '1234');
    expect(fake.signQuery!['signCode'], '1234');

    fake.checkSignCodeResult = 1;
    expect(await chaoxingCheckSignCode(client, activeId: 501, signCode: '1234'), isTrue);
    fake.checkSignCodeResult = 0;
    expect(await chaoxingCheckSignCode(client, activeId: 501, signCode: '9999'), isFalse);
  });

  test('登录失败与密码位数在客户端先拦下', () async {
    final fake = await FakeChaoxing.create();
    final http = ChaoxingHttp(client: fake.client());
    await expectLater(
      ChaoxingClient.signIn(http: http, phoneNumber: '13800138000', password: 'wrongPassword'),
      throwsA(isA<ChaoxingFailure>().having((failure) => failure.code, 'code', ChaoxingFailureCode.login)),
    );
    await expectLater(
      ChaoxingClient.signIn(http: http, phoneNumber: '13800138000', password: 'short'),
      throwsA(isA<ChaoxingFailure>().having((failure) => failure.code, 'code', ChaoxingFailureCode.invalidInput)),
    );
  });

  test('二维码两种形态都能解出来', () {
    final signed = chaoxingParseQrCode('SIGNIN:id=501&enc=ENCVALUE-1.2.3');
    expect(signed?.activeId, 501);
    expect(signed?.enc, 'ENCVALUE');
    expect(signed?.code, '501');

    final url = chaoxingParseQrCode('https://mobilelearn.chaoxing.com/newsign/preSign?enc=ENC2&id=502&c=99');
    expect(url?.enc, 'ENC2');
    expect(url?.activeId, 502);
    expect(url?.code, '99');

    for (final bad in ['', '  ', 'hello', 'https://example.com/x', 'SIGNIN:abc', 'SIGNIN:id=1']) {
      expect(chaoxingParseQrCode(bad), isNull, reason: bad);
    }
  });

  test('二维码过期按 signDetail 判定', () async {
    final fake = await FakeChaoxing.create();
    final client = await ChaoxingClient.signIn(
      http: ChaoxingHttp(client: fake.client()),
      phoneNumber: '13800138000',
      password: 'myPassword123',
    );
    const code = ChaoxingQrCode(enc: 'E', activeId: 501, code: '501');
    fake.signDetail = {'isOver': 0, 'signCode': '501'};
    expect(await chaoxingQrCodeExpired(client, code: code, activeId: 501), isFalse);
    fake.signDetail = {'isOver': 1, 'signCode': '501'};
    expect(await chaoxingQrCodeExpired(client, code: code, activeId: 501), isTrue);
    fake.signDetail = {'isOver': 0, 'signCode': '999'};
    expect(await chaoxingQrCodeExpired(client, code: code, activeId: 501), isTrue);
  });

  test('二维码签到带 enc，活动号以二维码为准', () async {
    final fake = await FakeChaoxing.create();
    fake.preSignHtml = '<script>signstatus = 0;</script>';
    final client = await ChaoxingClient.signIn(
      http: ChaoxingHttp(client: fake.client()),
      phoneNumber: '13800138000',
      password: 'myPassword123',
    );
    await chaoxingSubmit(
      client,
      ChaoxingSignSubmission(activity: _activity(ChaoxingSignType.qrCode), activeId: 900, enc: 'ENCV'),
    );
    expect(fake.signQuery!['enc'], 'ENCV');
    expect(fake.signQuery!['activeId'], '900');
  });

  test('滑块验证码的参数与提交按已知答案钉住', () async {
    final fake = await FakeChaoxing.create();
    final client = await ChaoxingClient.signIn(
      http: ChaoxingHttp(client: fake.client()),
      phoneNumber: '13800138000',
      password: 'myPassword123',
    );
    final activity = _activity(ChaoxingSignType.location);
    final referer = chaoxingPreSignRequestUri(activity: activity, account: client.account!);
    final puzzle = await chaoxingCaptchaPuzzle(client, referer: referer, uuid: () => 'fixed-uuid');
    expect(puzzle.shadeImageUrl, 'https://captcha.chaoxing.com/captcha/shade.png');
    expect(puzzle.cutoutImageUrl, contains('cutout.png'));
    // captchaKey = md5(t + uuid)，token = md5(t + captchaId + type + captchaKey) + ":" + (t + 300000)：
    // 这两个是取图请求带的参数，校验用的是响应回来的 token。
    expect(fake.captchaImageQuery, contains('captchaKey=0ad632d15e23de3797be7575fa092d34'));
    expect(fake.captchaImageQuery, contains('token=752f10771d809f87daf9c93512a1f5ec%3A1700000300000'));
    expect(fake.captchaImageQuery, contains('captchaId=$chaoxingCaptchaId'));
    expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(puzzle.iv), isTrue);
    expect(puzzle.token, fake.captchaToken);
    expect(fake.captchaCalls, contains('/captcha/get/conf'));
    expect(fake.captchaCalls, contains('/captcha/get/verification/image'));

    final image = await chaoxingCaptchaImage(client, puzzle.shadeImageUrl);
    expect(picture.decodePng(image)?.width, 280);

    final passed = await chaoxingCaptchaVerify(client, puzzle: puzzle, position: 123.4, referer: referer);
    expect(passed.passed, isTrue);
    expect(passed.validate, 'captcha-validate');
    expect(fake.captchaResultQuery, contains('textClickArr=%5B%7B%22x%22%3A123%7D%5D'));
    expect(fake.captchaResultQuery, contains('token=${fake.captchaToken}'));
    expect(fake.captchaReferer, referer.toString());

    fake.captchaPassed = false;
    final failed = await chaoxingCaptchaVerify(client, puzzle: puzzle, position: 10, referer: referer);
    expect(failed.passed, isFalse);
    expect(failed.validate, isNull);

    fake.captchaPassed = true;
    fake.captchaError = 1;
    final expired = await chaoxingCaptchaVerify(client, puzzle: puzzle, position: 10, referer: referer);
    expect(expired.passed, isFalse);
    expect(expired.message, '验证码已失效');
  });

  test('滑块位置按 280 宽的坐标空间换算', () {
    expect(chaoxingCaptchaPosition(0, 224), -8);
    expect(chaoxingCaptchaPosition(112, 224), closeTo(132, 1e-9));
    expect(chaoxingCaptchaPosition(224, 224), 272);
    expect(chaoxingCaptchaPosition(10, 0), -8);
  });

  test('拍照签到的照片会随机裁剪旋转后再上传', () {
    final source = picture.encodeJpg(picture.Image(width: 600, height: 400));
    final stylized = chaoxingStylizePhoto(source, random: Random(5));
    final decoded = picture.decodeImage(stylized);
    expect(decoded, isNotNull);
    // 先裁到 90%~99%，再按旋转后的安全内接矩形收一次（5 度时约再收 11%）。
    expect(decoded!.width, lessThan(600 * 0.995));
    expect(decoded.width, greaterThan(600 * 0.78));
    expect(decoded.height, lessThan(400));
    expect((decoded.width / decoded.height), closeTo(1.5, 0.05));
    expect(chaoxingStylizePhoto(source, random: Random(9)), isNot(equals(stylized)));
    expect(() => chaoxingStylizePhoto([1, 2, 3]), throwsA(isA<ChaoxingFailure>()));
  });

  test('拍照签到：风格化后传云盘，再带 objectId 提交', () async {
    final fake = await FakeChaoxing.create();
    final client = await ChaoxingClient.signIn(
      http: ChaoxingHttp(client: fake.client()),
      phoneNumber: '13800138000',
      password: 'myPassword123',
    );
    final source = picture.encodeJpg(picture.Image(width: 300, height: 200));
    final objectId = await chaoxingUploadPhoto(client, bytes: chaoxingStylizePhoto(source, random: Random(2)));
    expect(objectId, 'obj-1');
    expect(fake.uploadQuery, contains('_from=mobilelearn'));
    expect(fake.uploadQuery, contains('_token=cloud-token'));
    expect(fake.uploadContentType, startsWith('multipart/form-data'));
    expect(fake.uploadBody, contains('name="puid"'));
    expect(fake.uploadBody, contains('name="file"'));
    expect(fake.uploadBody, contains('.jpg'));

    await chaoxingSubmit(client, ChaoxingSignSubmission(activity: _activity(ChaoxingSignType.photo), objectId: objectId));
    expect(fake.signQuery!['objectId'], 'obj-1');
  });

  test('签退状态与跳转目标', () {
    expect(chaoxingActiveInfoFrom({'signInId': 0, 'signOutId': 0, 'signOutPublishTimeStamp': 4999}).signOutState, ChaoxingSignOutState.none);
    expect(chaoxingActiveInfoFrom({'signInId': 502}).relatedActiveId, 502);
    expect(chaoxingActiveInfoFrom({'signOutId': 503, 'signOutPublishTimeStamp': 1760000000000}).relatedActiveId, 503);
    expect(chaoxingActiveInfoFrom({'signOutPublishTimeStamp': 1760000000000}).relatedActiveId, isNull);
    final info = chaoxingActiveInfoFrom({'otherId': '2', 'nameOne': '签到', 'starttime': 1760000000000, 'endTime': 1760000600000});
    expect(info.signType, ChaoxingSignType.qrCode);
    expect(info.title, '签到');
    expect(info.startTime?.millisecondsSinceEpoch, 1760000000000);
    expect(info.endTime?.millisecondsSinceEpoch, 1760000600000);
  });

  test('人脸公钥解析出 1024 位模数', () {
    final modulus = chaoxingRsaModulus();
    expect(modulus, isNotNull);
    expect(modulus!.bitLength, 1024);
    expect(
      modulus.toRadixString(16),
      'bbf5df0eb748426f1c522120bac7c482c1306ca454b394b28725462aa0536ed5'
      '34916b0e2111890e9ef11a2f5572a3157a1d7703af3c18bda15969968f40f16'
      '77c21d9cb9750c3172689f8121ea4bea0a5f0e3462ce1c548aa753977dd12ec4'
      '59245d060957e3cf6396a55a35c412903c764d8982f836c0abd155fc1534f4849',
    );
    // 不是合法 base64 或长度不对时一律当作解不出来。
    expect(chaoxingDecryptClientId('%%%'), isNull);
    expect(chaoxingDecryptClientId('AAAA'), isNull);
    expect(chaoxingDecryptClientId(''), isNull);
  });

  test('人脸签名的字段按 key 排序拼接后加 sc 做 md5', () {
    expect(
      chaoxingFaceSignToken(
        fields: {
          'currentFaceId': 'obj-1',
          'LiveDetectionStatus': '1',
          'collectStatus': '1',
          'cxtime': '1700000000000',
          // cxcid 也要参与拼串（与参考实现的 TreeMap 口径一致），只写进上报 JSON 会导致服务端校验签名不通过。
          'cxcid': 'cid-value',
        },
        secret: 'secret-value',
      ),
      // 排序按 UTF-16 码元，大写字母在前，与参考实现的 TreeMap 一致。
      '665e15cb0025c2dd1acf6534e40bab17',
    );
  });

  test('人脸 faceResult 与换取 faceEnc', () async {
    final fake = await FakeChaoxing.create();
    final client = await ChaoxingClient.signIn(
      http: ChaoxingHttp(client: fake.client()),
      phoneNumber: '13800138000',
      password: 'myPassword123',
    );

    // 没有 clientId 时只带最基本的几个字段（测试账号登录返回里没有 clientId）。
    final result = await chaoxingFaceResult(client, objectId: 'obj-9', now: DateTime.fromMillisecondsSinceEpoch(1700000000000));
    expect(result['currentFaceId'], 'obj-9');
    expect(result['LiveDetectionStatus'], 1);
    expect(result['collectStatus'], 1);
    expect(result['cxtime'], '1700000000000');
    expect(result.containsKey('signToken'), isFalse);

    expect(await chaoxingProfileFaceObjectId(client), 'face-object-1');

    final enc = await chaoxingFaceEnc(client, activeId: 501, objectId: 'face-object-1');
    expect(enc, 'FACE-ENC');
    expect(fake.faceQuery!['activeId'], '501');
    expect(fake.faceQuery!['faceResult'], contains('"currentFaceId":"face-object-1"'));
  });

  test('preSign 返回 302 视为不在班级；analysis 抠不到 code 时不拦签到', () async {
    final fake = await FakeChaoxing.create();
    final client = await ChaoxingClient.signIn(
      http: ChaoxingHttp(client: fake.client()),
      phoneNumber: '13800138000',
      password: 'myPassword123',
    );
    fake.preSignStatusCode = 302;
    await expectLater(
      chaoxingPreSign(client, _activity(ChaoxingSignType.password)),
      throwsA(isA<ChaoxingFailure>().having((failure) => failure.code, 'code', ChaoxingFailureCode.noPermission)),
    );
    fake.preSignStatusCode = 200;
    fake.preSignHtml = '<script>signstatus = 0;</script>';
    fake.analysisPage = '<html>改版了</html>';
    expect(await chaoxingPreSign(client, _activity(ChaoxingSignType.password)), ChaoxingPreSignStatus.readyToSign);
    expect(fake.analysis2Code, isNull);
  });

  test('迟到按活动截止时间判断，截止前提交成功不算迟到', () async {
    final fake = await FakeChaoxing.create();
    final client = await ChaoxingClient.signIn(
      http: ChaoxingHttp(client: fake.client()),
      phoneNumber: '13800138000',
      password: 'myPassword123',
    );
    final ended = ChaoxingActivity(
      activeId: 501,
      courseId: 9001,
      classId: 88,
      title: '签到',
      subtitle: '高等数学',
      signType: ChaoxingSignType.password,
      startTime: DateTime.utc(2026, 1, 1),
      endTime: DateTime.utc(2026, 1, 1, 1),
      status: 2,
      userStatus: 0,
      ext: '{}',
    );
    expect((await chaoxingSubmit(client, ChaoxingSignSubmission(activity: ended, signCode: '1'))).late, isTrue);
    expect((await chaoxingSubmit(client, ChaoxingSignSubmission(activity: _activity(ChaoxingSignType.password), signCode: '1'))).late, isFalse);
  });

  test('课程频道只认带 cataName 的课程条目', () {
    final courses = chaoxingCourseList([
      {
        'cataName': '课程',
        'content': {
          'id': 88,
          'course': {
            'data': [
              {'id': 9001, 'name': '高等数学', 'schools': '示例大学'},
            ],
          },
        },
      },
      {
        'content': {
          'id': 99,
          'course': {
            'data': [
              {'id': 9002, 'name': '文件夹里的东西'},
            ],
          },
        },
      },
    ]);
    expect(courses.map((course) => course.classId), [88]);
    expect(courses.single.schools, '示例大学');
  });

  test('学校单位：主单位在前，其余单位去重补名', () {
    final units = chaoxingUnits({
      'fid': 100,
      'schoolname': '',
      'unitConfigInfos': [
        {'fid': 100, 'schoolname': '甲大学'},
        {'fid': 200, 'schoolname': '乙培训'},
        {'fid': 200, 'schoolname': '重复的'},
        {'schoolname': '缺 fid'},
      ],
    });
    expect(units.map((unit) => unit.fid), [100, 200]);
    expect(units.map((unit) => unit.name), ['甲大学', '乙培训']);
    expect(chaoxingUnits({'fid': 7}).single.name, chaoxingUnknownSchool);
  });

  test('设备码按 OAID 做 AES-ECB，与 openssl 的已知答案一致', () async {
    expect(
      chaoxingDeviceCodeFromOaid('c8b3a6e1-2f4d-4b7a-9e10-5d3f2a1b0c9e'),
      'Dpl3RndTUkExstIDHs+8jXL69FRpyroc/Qy6m93xDqTDWqVMeZPr2+vbQ2U03Mt2',
    );
    expect(await chaoxingLocalDeviceCode(_FakeProbe(oaidValue: 'c8b3a6e1-2f4d-4b7a-9e10-5d3f2a1b0c9e')), startsWith('Dpl3'));
    // 取不到或全 0 占位的 OAID 不算，交给固定随机设备码。
    expect(await chaoxingLocalDeviceCode(_FakeProbe(oaidValue: '00000000-0000-0000-0000-000000000000')), '');
    expect(await chaoxingLocalDeviceCode(_FakeProbe()), '');
    expect(await chaoxingLocalDeviceCode(null), '');
  });

  test('设备信息的字段与顺序照学习通客户端，RSA 按 117 字节分块', () async {
    final info = chaoxingDeviceInfo(
      await _FakeProbe().facts('com.chaoxing.mobile'),
      packageName: 'com.chaoxing.mobile',
      now: DateTime.fromMillisecondsSinceEpoch(1700000000000),
    );
    expect(info.keys.toList(), [
      'deviceUniqueId', 'cdid', 'device_id', 'android_id', 'mediaDrmId', 'oaid', 'platform', 'os_name', 'os_ver',
      'os_lang', 'brand', 'board', 'hardware', 'model', 'cpu_ar', 'app_name', 'app_ver', 'versionCode', 'signatures',
      'resolution', 'dpi', 'time_stamp',
    ]);
    expect(info['deviceUniqueId'], 'fdc5e0753d6c23b346baac7be567f0892db04678c36c482ff8f7245ba95573c5');
    expect(info['app_ver'], chaoxingDefaultAppVersion);
    expect(info['signatures'], chaoxingDefaultSignature);
    expect(info['resolution'], '1080*2400');
    expect(info['time_stamp'], 1700000000000);
    final plain = utf8.encode(jsonEncode(info));
    final encrypted = base64.decode(chaoxingRsaEncrypt(plain));
    expect(encrypted.length, (plain.length / chaoxingRsaPlainBlockBytes).ceil() * chaoxingRsaBlockBytes);
  });

  test('有设备信息时用户信息改用 POST 带 data，并收下 clientId', () async {
    final fake = await FakeChaoxing.create();
    fake.clientId = 'client-id-1';
    final http = ChaoxingHttp(client: fake.client());
    final client = await ChaoxingClient.signIn(
      http: http,
      phoneNumber: '13800138000',
      password: 'myPassword123',
      device: _FakeProbe(),
    );
    expect(fake.userInfoMethod, 'POST');
    expect(Uri.splitQueryString(fake.userInfoBody!)['data'], isNotEmpty);
    expect(client.account!.clientId, 'client-id-1');

    final plain = await ChaoxingClient.signIn(http: ChaoxingHttp(client: fake.client()), phoneNumber: '13800138000', password: 'myPassword123');
    expect(fake.userInfoMethod, 'GET');
    expect(plain.account!.units.single.fid, 1234);
  });

  test('模拟的客户端换了，请求的 UA 跟着换', () {
    expect(ChaoxingClientProfile.xuezaixidian.userAgent, contains('com.chaoxing.mobile.xuezaixidian'));
    expect(ChaoxingClientProfile.userAgentProblem(''), isNotNull);
    expect(ChaoxingClientProfile.userAgentProblem('含中文的 UA'), isNotNull);
    expect(ChaoxingClientProfile.userAgentProblem('Dalvik/2.1.0'), isNull);
    expect(ChaoxingClientProfile.custom(userAgent: ' UA ').packageName, ChaoxingClientProfile.chaoxing.packageName);
  });

  test('学习通课表：节次换算、本周的课与当前时段', () {
    final table = chaoxingParseLessons({
      'curriculum': {
        'lessonTimeConfigArray': ['08:00-08:45', '08:55-09:40', '10:00-10:45'],
        // 2026-09-07（周一）零点，北京时间。
        'firstWeekDate': DateTime.utc(2026, 9, 6, 16).millisecondsSinceEpoch,
      },
      'lessonArray': [
        {'name': '高等数学（一）', 'dayOfWeek': 3, 'beginNumber': 1, 'length': 2, 'weeks': '1,2,5', 'classId': 0, 'courseId': 0},
        {'name': '缺节次', 'dayOfWeek': 3, 'beginNumber': 9, 'weeks': '5'},
        {'name': '', 'dayOfWeek': 3, 'beginNumber': 1, 'weeks': '5'},
      ],
    });
    expect(table.lessons, hasLength(1));
    expect(table.lessons.single.startMinute, 8 * 60);
    expect(table.lessons.single.endMinute, 9 * 60 + 40);
    // 2026-10-07 是第 5 周的周三；北京时间 09:30 在课上，11:00 已过下课 30 分钟之外。
    expect(chaoxingCurrentWeek(table.firstWeekDate, DateTime.utc(2026, 10, 7, 1, 30)), 5);
    expect(chaoxingCurrentLessons(table, DateTime.utc(2026, 10, 7, 1, 30)), hasLength(1));
    expect(chaoxingCurrentLessons(table, DateTime.utc(2026, 10, 7, 3, 11)), isEmpty);
    expect(chaoxingCurrentLessons(table, DateTime.utc(2026, 10, 8, 1, 30)), isEmpty);
    expect(() => chaoxingParseLessons({'curriculum': 1}), throwsA(isA<ChaoxingFailure>()));
  });

  test('课表课名与课程列表课名：归一化、互相包含或二元组相似', () {
    expect(chaoxingNormalizeCourseName('高等数学（一）'), '高等数学');
    expect(chaoxingNormalizeCourseName('Ｃ语言 程序设计 II'), 'c语言程序设计');
    expect(chaoxingCourseNameMatches('高等数学（一）', '高等数学A'), isTrue);
    expect(chaoxingCourseNameMatches('大学英语', '大学英语读写'), isTrue);
    expect(chaoxingCourseNameMatches('马克思主义基本原理概论', '马克思主义原理'), isTrue);
    expect(chaoxingCourseNameMatches('高等数学', '大学物理'), isFalse);
    const courses = [
      ChaoxingCourse(courseId: 1, classId: 11, name: '高等数学A'),
      ChaoxingCourse(courseId: 2, classId: 22, name: '大学物理'),
    ];
    const lesson = ChaoxingLesson(courseId: 0, classId: 0, courseName: '高等数学（一）', dayOfWeek: 1, startMinute: 0, endMinute: 1, weeks: {1});
    expect(chaoxingLessonCourses([lesson], courses).map((course) => course.classId), [11]);
    final now = DateTime.utc(2026, 10, 7, 1);
    final fresh = ChaoxingActivity(activeId: 1, courseId: 1, classId: 11, title: '签到', subtitle: '', signType: ChaoxingSignType.password, startTime: now.subtract(const Duration(minutes: 5)), status: 1, userStatus: 0, ext: '');
    expect(chaoxingFreshActivity(fresh, now), isTrue);
    expect(chaoxingFreshActivity(fresh, now.add(const Duration(minutes: 30))), isFalse);
  });
}
