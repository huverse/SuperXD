import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart' as castle;

import 'package:superxd/toolbox/chaoxing/chaoxing_client.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_http.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';

// 群聊签到：学习通的群聊走环信，签到以自定义附件的形式发在群里。
// 先用学习通账号换环信令牌（密码是登录时下发的 DES 密文），再按群拉漫游消息；消息体是 protobuf，只读我们需要的三段。
const chaoxingImSecretKey = 'SL2(M/eD';
const chaoxingImTokenUri = 'https://a1-vip6.easemob.com/cx-dev/cxstudy/token';
const chaoxingImUserAgent = 'Easemob-SDK(Android) 4.9.0.1';
const chaoxingImGroupLimit = 50;
const chaoxingImMessageLimit = 20;

// 登录响应里的环信密码是 DES/ECB/PKCS5 的十六进制密文。
// pointycastle 只带 3DES，三段用同一把钥匙时 3DES 就等于单 DES，所以拿它当 DES 用（测试对着 openssl 的向量钉住）。
String chaoxingImPassword(String encryptedHex) {
  final bytes = _hexToBytes(encryptedHex);
  if (bytes.isEmpty || bytes.length % 8 != 0) {
    throw const ChaoxingFailure(ChaoxingFailureCode.server, '群聊密码读不出来，请重新登录后再试');
  }
  final key = utf8.encode(chaoxingImSecretKey);
  final cipher = castle.PaddedBlockCipherImpl(
    castle.PKCS7Padding(),
    castle.ECBBlockCipher(castle.DESedeEngine()),
  )..init(
    false,
    castle.PaddedBlockCipherParameters<castle.KeyParameter, Null>(
      castle.KeyParameter(Uint8List.fromList([...key, ...key, ...key])),
      null,
    ),
  );
  final plain = cipher.process(Uint8List.fromList(bytes));
  final text = utf8.decode(plain, allowMalformed: true);
  if (utf8.encode(text).length != plain.length) {
    throw const ChaoxingFailure(ChaoxingFailureCode.server, '群聊密码读不出来，请重新登录后再试');
  }
  return text;
}

Uint8List _hexToBytes(String hex) {
  if (hex.length.isOdd) return Uint8List(0);
  final bytes = Uint8List(hex.length ~/ 2);
  for (var index = 0; index < bytes.length; index++) {
    final byte = int.tryParse(hex.substring(index * 2, index * 2 + 2), radix: 16);
    if (byte == null) return Uint8List(0);
    bytes[index] = byte;
  }
  return bytes;
}

class ChaoxingImConfig {
  const ChaoxingImConfig({required this.token, required this.username});
  final String token;
  final String username;
}

class ChaoxingImGroup {
  const ChaoxingImGroup({required this.id, required this.name});
  final String id;
  final String name;
}

// 群聊里announced的一场签到。
class ChaoxingImActivity {
  const ChaoxingImActivity({
    required this.activeId,
    required this.classId,
    required this.courseId,
    required this.courseName,
    required this.title,
    required this.atypeName,
    required this.groupName,
  });
  final int activeId;
  final int classId;
  final int courseId;
  final String courseName;
  final String title;

  // 群聊里带的签到类型名；认不出来的要去活动详情里问。
  final String atypeName;
  final String groupName;
}

// 群聊里带的类型名与活动列表里的 otherId 是一套语义。
ChaoxingSignType? chaoxingSignTypeOfAtypeName(String name) => switch (name) {
  '密码签到' => ChaoxingSignType.password,
  '位置签到' => ChaoxingSignType.location,
  '二维码签到' => ChaoxingSignType.qrCode,
  '拍照签到' => ChaoxingSignType.photo,
  '手势签到' => ChaoxingSignType.gesture,
  _ => null,
};

Future<ChaoxingImConfig> chaoxingImConfig(ChaoxingClient client) async {
  final account = client.account;
  if (account == null || account.imPassword.isEmpty) {
    throw const ChaoxingFailure(ChaoxingFailureCode.unavailable, '这个账号拿不到群聊凭证，请重新登录后再试');
  }
  final password = chaoxingImPassword(account.imPassword);
  final response = await client.http.postForm(
    Uri.parse(chaoxingImTokenUri),
    jsonEncode({'grant_type': 'password', 'password': password, 'username': '${account.uid}'}),
    headers: {'User-Agent': chaoxingImUserAgent},
    timeout: const Duration(seconds: 20),
  );
  final json = chaoxingJson(response.body);
  final token = chaoxingString(json['access_token']);
  final user = json['user'];
  final username = user is Map ? chaoxingString(user['username']) : '';
  if (token.isEmpty || username.isEmpty) {
    throw const ChaoxingFailure(ChaoxingFailureCode.sessionExpired, '群聊登录失败，请重新登录学习通账号');
  }
  return ChaoxingImConfig(token: token, username: username);
}

Future<List<ChaoxingImGroup>> chaoxingImGroups(ChaoxingClient client, ChaoxingImConfig config) async {
  final response = await client.http.get(
    Uri.parse(
      'https://a1-vip6.easemob.com/cx-dev/cxstudy/users/${config.username}/joined_chatgroups'
      '?detail=true&version=v3&pagenum=1&pagesize=$chaoxingImGroupLimit',
    ),
    headers: {'Authorization': 'Bearer ${config.token}', 'User-Agent': chaoxingImUserAgent},
    timeout: const Duration(seconds: 20),
  );
  final data = chaoxingJson(response.body)['data'];
  if (data is! List) return const [];
  final groups = <ChaoxingImGroup>[];
  for (final item in data) {
    if (item is! Map) continue;
    final id = chaoxingString(item['id']);
    if (id.isEmpty) continue;
    groups.add(ChaoxingImGroup(id: id, name: chaoxingString(item['name'])));
  }
  return groups;
}

// 把群里能签到的活动都找出来：逐群拉漫游并去重。
Future<List<ChaoxingImActivity>> chaoxingImActivities(ChaoxingClient client, {int groupLimit = chaoxingImGroupLimit}) async {
  final config = await chaoxingImConfig(client);
  final groups = await chaoxingImGroups(client, config);
  final activities = <ChaoxingImActivity>[];
  for (final group in groups.take(groupLimit)) {
    activities.addAll(await chaoxingImGroupActivities(client, config: config, group: group));
  }
  final seen = <int>{};
  return [
    for (final activity in activities)
      if (seen.add(activity.activeId)) activity,
  ];
}

// 拉一个群的漫游消息，从里面挑出签到附件。
Future<List<ChaoxingImActivity>> chaoxingImGroupActivities(
  ChaoxingClient client, {
  required ChaoxingImConfig config,
  required ChaoxingImGroup group,
}) async {
  final response = await client.http.postForm(
    Uri.parse('https://a1-vip6.easecdn.com/cx-dev/cxstudy/users/${config.username}/messageroaming'),
    jsonEncode({'end': '-1', 'queue': '${group.id}@conference.easemob.com', 'start': '-1'}),
    contentType: 'text/plain;charset=UTF-8',
    headers: {'Authorization': 'Bearer ${config.token}', 'User-Agent': chaoxingImUserAgent},
    timeout: const Duration(seconds: 20),
  );
  // 这一条接口的响应是 JSON，正文里每条消息的 msg 字段是 base64 的 protobuf。
  final body = jsonDecode(response.body);
  if (body is! Map) return const [];
  final data = body['data'];
  final messages = data is Map ? data['msgs'] : null;
  if (messages is! List) return const [];
  final activities = <ChaoxingImActivity>[];
  for (final message in messages) {
    if (message is! Map) continue;
    final encoded = chaoxingString(message['msg']);
    if (encoded.isEmpty) continue;
    final List<int> bytes;
    try {
      bytes = base64.decode(encoded);
    } on FormatException {
      continue;
    }
    for (final attachment in chaoxingImAttachments(bytes)) {
      final activity = chaoxingImActivityOf(attachment, group.name);
      if (activity != null) activities.add(activity);
    }
  }
  return activities;
}

// Meta.field6 里是 MessageBody；它的 ext 里 key 为 attachment 的那几项是签到附件。
List<Map<String, Object?>> chaoxingImAttachments(List<int> metaBytes) {
  final attachments = <Map<String, Object?>>[];
  for (final field in _protoFields(metaBytes)) {
    if (field.field != 6) continue;
    for (final ext in _protoFields(field.bytes)) {
      if (ext.field != 5) continue;
      String? key;
      String? value;
      for (final item in _protoFields(ext.bytes)) {
        if (item.field == 1) key = utf8.decode(item.bytes, allowMalformed: true);
        if (item.field == 6) value = utf8.decode(item.bytes, allowMalformed: true);
      }
      if (key != 'attachment' || value == null) continue;
      try {
        final decoded = jsonDecode(value);
        if (decoded is Map) attachments.add(decoded.cast<String, Object?>());
      } on FormatException {
        continue;
      }
    }
  }
  return attachments;
}

// 附件里只有 attachmentType 为 15、活动类型是签到的才是签到；其余（公告、作业等）跳过。
ChaoxingImActivity? chaoxingImActivityOf(Map<String, Object?> attachment, String groupName) {
  if (chaoxingInt(attachment['attachmentType']) != 15) return null;
  final signInfo = attachment['att_chat_course'];
  if (signInfo is! Map) return null;
  final activeId = chaoxingInt(signInfo['aid']);
  final atype = chaoxingInt(signInfo['atype']);
  if (activeId == 0 || (atype != 2 && atype != 74)) return null;
  final courseInfo = signInfo['courseInfo'];
  final course = courseInfo is Map ? courseInfo : const <String, Object?>{};
  return ChaoxingImActivity(
    activeId: activeId,
    classId: chaoxingInt(course['classid']),
    courseId: chaoxingInt(course['courseid']),
    courseName: chaoxingString(course['coursename']),
    title: chaoxingString(signInfo['title']),
    atypeName: chaoxingString(signInfo['atypeName']),
    groupName: groupName,
  );
}

typedef _ProtoField = ({int field, Uint8List bytes});

// 极简 protobuf 读取：只认长度分隔（wire type 2）的字段，够读环信消息里的三段嵌套。
List<_ProtoField> _protoFields(List<int> bytes) {
  final fields = <_ProtoField>[];
  var offset = 0;
  while (offset < bytes.length) {
    final (tag, nextOffset) = _readVarint(bytes, offset);
    if (tag == null) break;
    offset = nextOffset;
    final field = tag >> 3;
    final wire = tag & 0x07;
    switch (wire) {
      case 0:
        final (_, afterValue) = _readVarint(bytes, offset);
        offset = afterValue;
      case 1:
        offset += 8;
      case 2:
        final (length, afterLength) = _readVarint(bytes, offset);
        if (length == null || afterLength + length > bytes.length) return fields;
        fields.add((field: field, bytes: Uint8List.fromList(bytes.sublist(afterLength, afterLength + length))));
        offset = afterLength + length;
      case 5:
        offset += 4;
      default:
        return fields;
    }
  }
  return fields;
}

(int?, int) _readVarint(List<int> bytes, int offset) {
  var value = 0;
  var shift = 0;
  var index = offset;
  while (index < bytes.length && shift < 64) {
    final byte = bytes[index++];
    value |= (byte & 0x7f) << shift;
    if (byte & 0x80 == 0) return (value, index);
    shift += 7;
  }
  return (null, index);
}
