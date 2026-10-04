import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/page/friend_add_page.dart';
import 'package:superxd/social/invite_code.dart';
import 'package:superxd/social/social_crypto.dart';

// 协议 v1 客户端密码学：与服务端共用 server/test/vectors/protocol_v1.json，双端逐字节一致。
void main() {
  final vectors = jsonDecode(File('server/test/vectors/protocol_v1.json').readAsStringSync()) as Map<String, dynamic>;

  group('测试向量', () {
    test('签名种子推出的公钥与设备号一致', () async {
      final seed = decodeBase64UrlNoPad(vectors['signSeed'] as String);
      final publicKey = await ed25519PublicOf(seed);
      expect(base64UrlNoPad(publicKey), vectors['signPublicKey']);
      expect(deviceIdOf(publicKey), vectors['deviceId']);
    });

    test('请求签名原文与签名逐字节一致（Ed25519 确定性签名）', () async {
      final request = vectors['request'] as Map<String, dynamic>;
      final canonical = requestCanonical(request['method'] as String, request['path'] as String, request['time'] as String, request['nonce'] as String, utf8.encode(request['body'] as String));
      expect(utf8.decode(canonical), request['canonical']);
      final signature = await signWithSeed(decodeBase64UrlNoPad(vectors['signSeed'] as String), canonical);
      expect(base64UrlNoPad(signature), request['signature']);
    });

    test('邀请凭证逐字节一致', () async {
      final invite = vectors['invite'] as Map<String, dynamic>;
      final canonical = inviteProofCanonical(invite['inviteId'] as String, invite['redeemerDeviceId'] as String);
      expect(utf8.decode(canonical), invite['canonical']);
      final seed = decodeBase64UrlNoPad(invite['seed'] as String);
      expect(base64UrlNoPad(await ed25519PublicOf(seed)), invite['publicKey']);
      expect(base64UrlNoPad(await signWithSeed(seed, canonical)), invite['proof']);
    });

    test('base64url 只认无填充的规范写法', () {
      expect(() => decodeBase64UrlNoPad('AA=='), throwsA(isA<SocialCryptoException>()));
      expect(() => decodeBase64UrlNoPad('A+A'), throwsA(isA<SocialCryptoException>()));
      expect(() => decodeBase64UrlNoPad(vectors['deviceId'] as String, length: 32), throwsA(isA<SocialCryptoException>()));
      expect(decodeBase64UrlNoPad(vectors['deviceId'] as String, length: 16), hasLength(16));
    });
  });

  group('端到端信封', () {
    late SocialIdentity alice, bob, eve;
    setUpAll(() async {
      alice = await SocialIdentity.generate();
      bob = await SocialIdentity.generate();
      eve = await SocialIdentity.generate();
    });
    PeerKeys keysOf(SocialIdentity identity) => PeerKeys(identity.signPublicKey, identity.boxPublicKey);

    test('收件人能解开并验签，中文内容原样还原', () async {
      final envelope = await sealEnvelope(sender: alice, recipient: keysOf(bob), message: {'kind': 'card', 'text': '周三下午一起自习'});
      final opened = await openEnvelope(recipient: bob, envelope: envelope);
      expect(opened.message['text'], '周三下午一起自习');
      expect(await verifyOpened(opened, alice.signPublicKey), isTrue);
      expect(await verifyOpened(opened, eve.signPublicKey), isFalse);
    });

    test('别人解不开；密文被改一字节即拒绝', () async {
      final envelope = await sealEnvelope(sender: alice, recipient: keysOf(bob), message: {'kind': 'card'});
      await expectLater(openEnvelope(recipient: eve, envelope: envelope), throwsA(isA<SocialCryptoException>()));
      final tampered = List<int>.of(envelope)..[60] ^= 1;
      await expectLater(openEnvelope(recipient: bob, envelope: tampered), throwsA(isA<SocialCryptoException>()));
    });

    test('同一内容每次加密结果不同（一次性密钥与随机数）', () async {
      final first = await sealEnvelope(sender: alice, recipient: keysOf(bob), message: {'kind': 'card'});
      final second = await sealEnvelope(sender: alice, recipient: keysOf(bob), message: {'kind': 'card'});
      expect(first, isNot(equals(second)));
    });

    test('压缩后才加密：重复内容很多的课表体积远小于原文', () async {
      final message = {'courses': List.generate(300, (index) => {'courseName': '高等数学', 'teacherName': '张老师', 'place': '教学楼A101', 'weeks': List.generate(16, (week) => week + 1)})};
      final envelope = await sealEnvelope(sender: alice, recipient: keysOf(bob), message: message);
      expect(envelope.length, lessThan(utf8.encode(jsonEncode(message)).length ~/ 5));
    });
  });

  group('好友二维码', () {
    test('编码解码往返，设备号由公钥推出', () async {
      final owner = await SocialIdentity.generate();
      final code = InviteCode(inviteId: base64UrlNoPad(randomBytes(16)), inviteSeed: randomBytes(32), owner: PeerKeys(owner.signPublicKey, owner.boxPublicKey), nickname: '小明', expiresAt: 1791100000000);
      final text = code.encode();
      expect(text, startsWith('SXD1F:'));
      // 全是 QR 字母数字模式字符（Base45），内容约 190 字符，纠错 M 下版本 8（49×49）即可装下。
      expect(RegExp(r'^[0-9A-Z $%*+\-./:]+$').hasMatch(text), isTrue);
      expect(inviteQrImage(text).moduleCount, lessThanOrEqualTo(49));
      // 昵称取满 20 个汉字时也不超过版本 10（57×57）。
      final longest = InviteCode(inviteId: code.inviteId, inviteSeed: code.inviteSeed, owner: code.owner, nickname: '汉' * 20, expiresAt: code.expiresAt).encode();
      expect(inviteQrImage(longest).moduleCount, lessThanOrEqualTo(57));
      final decoded = InviteCode.decode(text)!;
      expect(decoded.owner.deviceId, owner.deviceId);
      expect(decoded.nickname, '小明');
      expect(decoded.inviteSeed, code.inviteSeed);
    });

    test('别的二维码与损坏内容返回 null', () {
      expect(InviteCode.decode('https://example.com'), isNull);
      expect(InviteCode.decode('SXD1F:abc'), isNull);
      expect(InviteCode.decode('SXD1F:${base45Encode([2, ...List.filled(130, 0)])}'), isNull, reason: '未知版本');
      expect(InviteCode.decode('SXD1F:${base45Encode([1, ...List.filled(120, 0)])}'), isNull, reason: '缺昵称');
    });

    test('Base45 与 RFC 9285 示例一致，非法输入返回 null', () {
      expect(base45Encode(utf8.encode('AB')), 'BB8');
      expect(base45Encode(utf8.encode('Hello!!')), '%69 VD92EX0');
      expect(base45Encode(utf8.encode('base-45')), 'UJCLQE7W581');
      expect(utf8.decode(base45Decode('QED8WEX0')!), 'ietf!');
      expect(base45Decode('GGW'), isNull, reason: '超过 65535');
      expect(base45Decode('a'), isNull);
      expect(base45Decode('ZZZZ'), isNull);
    });

    test('昵称：1–20 字、无首尾空白与控制字符', () {
      expect(validNickname('小明'), isTrue);
      expect(validNickname('😀' * 20), isTrue);
      expect(validNickname('😀' * 21), isFalse);
      expect(validNickname(' 小明'), isFalse);
      expect(validNickname(''), isFalse);
      expect(validNickname('a\nb'), isFalse);
    });
  });
}
