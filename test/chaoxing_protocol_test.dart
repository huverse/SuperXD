import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as picture;

import 'package:superxd/toolbox/chaoxing/chaoxing_activity.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_captcha.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_client.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_crypto.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_http.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_location.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_photo.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_qrcode.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_signer.dart';

import 'chaoxing_fake_server.dart';

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
    expect((chaoxingSignOutcome('success2') as ChaoxingSignSucceeded).late, isTrue);
    expect(
      chaoxingSignOutcome('validate_enc2value'),
      isA<ChaoxingSignNeedsCaptcha>().having((value) => value.enc2, 'enc2', 'enc2value'),
    );
    for (final (body, code) in [
      ('您已签到过了', ChaoxingFailureCode.alreadySigned),
      ('签到失败，请重新扫描。', ChaoxingFailureCode.qrCodeExpired),
      ('errorLocation_123.4', ChaoxingFailureCode.wrongPosition),
      ('checkFace_abc', ChaoxingFailureCode.faceRequired),
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
      submission: ChaoxingSignSubmission(activity: _activity(ChaoxingSignType.qrCode), enc: 'ENCVALUE'),
    ).queryParameters;
    expect(qrQuery['enc'], 'ENCVALUE');

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
    expect(jsonDecode(query['locationResult']!)[ 'latitude'], closeTo(latitude, 1e-9));

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

  test('列表只收签到类活动，认不出的类型不入列', () {
    final course = const ChaoxingCourse(courseId: 9001, classId: 88, name: '高等数学');
    final parsed = [
      {'id': 1, 'type': 2, 'otherId': '4', 'nameOne': '签到', 'nameFour': '高等数学', 'startTime': 1760000000000, 'ext': {'a': 1}},
      {'id': 2, 'type': 74, 'otherId': '5', 'nameOne': '签到码', 'startTime': 1760000000000},
      {'id': 3, 'type': 3, 'otherId': '4', 'nameOne': '作业', 'startTime': 1760000000000},
      {'id': 4, 'type': 2, 'otherId': '9', 'nameOne': '未知类型', 'startTime': 1760000000000},
      {'id': 0, 'type': 2, 'otherId': '4', 'nameOne': '缺 id', 'startTime': 1760000000000},
    ].map((json) => chaoxingActivity(json.cast<String, Object?>(), course)).toList();
    expect(parsed.whereType<ChaoxingActivity>().map((activity) => activity.activeId), [1, 2]);
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
    expect(await chaoxingPreSign(client, activities.single), ChaoxingPreSignStatus.readyToSign);
    expect(jsonDecode(Uri.splitQueryString(fake.preSignBody!)['ext']!), {'a': 1});

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
}
