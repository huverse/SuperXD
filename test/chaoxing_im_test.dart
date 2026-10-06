import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/toolbox/chaoxing/chaoxing_client.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_http.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_im.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';

import 'chaoxing_fake_server.dart';

// 极简 protobuf 编码，用来造环信消息的测试数据（真实编码由真机联调覆盖）。
List<int> _varint(int value) {
  final bytes = <int>[];
  var remaining = value;
  while (remaining > 0x7f) {
    bytes.add((remaining & 0x7f) | 0x80);
    remaining >>= 7;
  }
  bytes.add(remaining);
  return bytes;
}

List<int> _bytesField(int field, List<int> bytes) => [..._varint((field << 3) | 2), ..._varint(bytes.length), ...bytes];

List<int> _meta(List<int> messageBody) => _bytesField(6, messageBody);

List<int> _ext(String key, String value) =>
    _bytesField(5, [..._bytesField(1, utf8.encode(key)), ..._bytesField(6, utf8.encode(value))]);

Map<String, Object?> _attachment({
  int activeId = 501,
  int atype = 2,
  String atypeName = '密码签到',
  int classId = 88,
  int courseId = 9001,
  String courseName = '高等数学',
  String title = '签到',
  int attachmentType = 15,
}) => {
  'attachmentType': attachmentType,
  'att_chat_course': {
    'aid': activeId,
    'atype': atype,
    'atypeName': atypeName,
    'title': title,
    'subTitle': '老师说开始签到了',
    'courseInfo': {'classid': classId, 'courseid': courseId, 'coursename': courseName},
  },
};

void main() {
  test('环信密码按 DES/ECB/PKCS5 解出明文（openssl 已知答案）', () {
    expect(chaoxingImPassword('9523f40340818f573b71a58235f15865'), 'im-password-1');
    expect(chaoxingImPassword('f6e35f05a42c5ec1'), 'hello');
    // 长度不是 8 的倍数、非十六进制、空串都算读不出来。
    for (final bad in ['', 'zz', '0102', 'ff']) {
      expect(() => chaoxingImPassword(bad), throwsA(isA<ChaoxingFailure>()), reason: bad);
    }
  });

  test('从漫游消息里取出 attachment 扩展，别的扩展与非 JSON 都跳过', () {
    final messages = [
      _meta(_ext('attachment', jsonEncode(_attachment()))),
      // 不是 attachment 的扩展
      _meta(_ext('other', jsonEncode(_attachment()))),
      // 内容不是 JSON
      _meta(_ext('attachment', 'not-json')),
      // 完全不是 protobuf
      [0xff, 0xff, 0xff],
    ];
    final attachments = [for (final message in messages) ...chaoxingImAttachments(message)];
    expect(attachments, hasLength(1));
    expect(attachments.single['attachmentType'], 15);

    // 挑签到这一步：附件类型不是 15、活动类型不是签到、缺活动号都不算。
    expect(chaoxingImActivityOf(attachments.single, '高等数学群')?.activeId, 501);
    expect(chaoxingImActivityOf(_attachment(attachmentType: 3), '群'), isNull);
    expect(chaoxingImActivityOf(_attachment(atype: 1), '群'), isNull);
    expect(chaoxingImActivityOf(_attachment(activeId: 0), '群'), isNull);
    expect(chaoxingImActivityOf(const <String, Object?>{}, '群'), isNull);
    final activity = chaoxingImActivityOf(_attachment(atype: 74, atypeName: '二维码签到'), '大学英语群');
    expect(activity?.courseId, 9001);
    expect(activity?.classId, 88);
    expect(activity?.groupName, '大学英语群');
    expect(chaoxingSignTypeOfAtypeName(activity!.atypeName), ChaoxingSignType.qrCode);
  });

  test('群聊里带的类型名映射成签到类型，认不出返回空', () {
    expect(chaoxingSignTypeOfAtypeName('密码签到'), ChaoxingSignType.password);
    expect(chaoxingSignTypeOfAtypeName('位置签到'), ChaoxingSignType.location);
    expect(chaoxingSignTypeOfAtypeName('二维码签到'), ChaoxingSignType.qrCode);
    expect(chaoxingSignTypeOfAtypeName('拍照签到'), ChaoxingSignType.photo);
    expect(chaoxingSignTypeOfAtypeName('手势签到'), ChaoxingSignType.gesture);
    expect(chaoxingSignTypeOfAtypeName('签到'), isNull);
    expect(chaoxingSignTypeOfAtypeName(''), isNull);
  });

  test('群聊链路：换令牌、列群、拉漫游取签到', () async {
    final fake = await FakeChaoxing.create();
    fake.imGroups.addAll([
      {'id': 'g1', 'name': '高等数学群'},
      {'id': 'g2', 'name': '大学英语群'},
    ]);
    fake.imMessages.addAll([
      _meta(_ext('attachment', jsonEncode(_attachment()))),
      _meta(_ext('attachment', jsonEncode(_attachment(activeId: 502, atype: 74, atypeName: '二维码签到', title: '第二次签到')))),
    ]);
    final client = await ChaoxingClient.signIn(
      http: ChaoxingHttp(client: fake.client()),
      phoneNumber: '13800138000',
      password: 'myPassword123',
    );

    final config = await chaoxingImConfig(client);
    expect(config.token, 'im-token');
    expect(config.username, 'cx_777');
    // 学习通下发的密文要被解成明文密码再发给环信。
    expect(fake.imTokenBody, contains('"password":"im-password-1"'));
    expect(fake.imTokenBody, contains('"username":"777"'));

    final groups = await chaoxingImGroups(client, config);
    expect(groups.map((group) => group.name), ['高等数学群', '大学英语群']);

    final activities = await chaoxingImGroupActivities(client, config: config, group: groups.first);
    expect(fake.imRoamingQueue, 'g1@conference.easemob.com');
    expect(activities.map((activity) => activity.activeId), [501, 502]);
    expect(activities.first.courseName, '高等数学');
    expect(activities.first.groupName, '高等数学群');
    expect(chaoxingSignTypeOfAtypeName(activities.last.atypeName), ChaoxingSignType.qrCode);
  });

  test('拿不到群聊凭证时如实报错', () async {
    final fake = await FakeChaoxing.create();
    fake.imPasswordHex = '';
    final client = await ChaoxingClient.signIn(
      http: ChaoxingHttp(client: fake.client()),
      phoneNumber: '13800138000',
      password: 'myPassword123',
    );
    await expectLater(
      chaoxingImConfig(client),
      throwsA(isA<ChaoxingFailure>().having((failure) => failure.code, 'code', ChaoxingFailureCode.unavailable)),
    );
  });
}
