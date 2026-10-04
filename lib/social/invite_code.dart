import 'dart:convert';
import 'dart:typed_data';

import 'package:superxd/social/social_crypto.dart';

const invitePrefix = 'SXD1F.';
const nicknameMaxLength = 20;

// 二维码内容：邀请号、邀请私钥种子、出示方公钥与昵称、过期时刻。
// 扫码方由此直接拿到出示方的真实公钥（当面交换，不经服务器），并用邀请私钥签出只对自己有效的凭证。
class InviteCode {
  const InviteCode({required this.inviteId, required this.inviteSeed, required this.owner, required this.nickname, required this.expiresAt});
  final String inviteId;
  final Uint8List inviteSeed;
  final PeerKeys owner;
  final String nickname;
  // 毫秒，服务器时间。
  final int expiresAt;

  String encode() => invitePrefix + base64UrlNoPad(utf8.encode(jsonEncode({
    'v': 1,
    'i': inviteId,
    'k': base64UrlNoPad(inviteSeed),
    's': base64UrlNoPad(owner.signPublicKey),
    'b': base64UrlNoPad(owner.boxPublicKey),
    'n': nickname,
    'e': expiresAt,
  })));

  // 扫到的任意文本都是外部输入：不是本应用的二维码返回 null，格式坏了同样返回 null。
  static InviteCode? decode(String text) {
    if (!text.startsWith(invitePrefix) || text.length > 2048) return null;
    try {
      final json = jsonDecode(utf8.decode(decodeBase64UrlNoPad(text.substring(invitePrefix.length))));
      if (json is! Map || json['v'] != 1) return null;
      final inviteId = json['i'], nickname = json['n'], expiresAt = json['e'];
      if (inviteId is! String || nickname is! String || expiresAt is! int) return null;
      decodeBase64UrlNoPad(inviteId, length: 16);
      if (!validNickname(nickname)) return null;
      return InviteCode(
        inviteId: inviteId,
        inviteSeed: decodeBase64UrlNoPad(json['k'] as String, length: 32),
        owner: PeerKeys(decodeBase64UrlNoPad(json['s'] as String, length: 32), decodeBase64UrlNoPad(json['b'] as String, length: 32)),
        nickname: nickname,
        expiresAt: expiresAt,
      );
    } on Object {
      return null;
    }
  }
}

// 昵称：1–20 个字符，去掉首尾空白，不含换行等控制字符。
bool validNickname(String value) => value.trim() == value && value.isNotEmpty && value.runes.length <= nicknameMaxLength && !RegExp(r'[\x00-\x1F\x7F]').hasMatch(value);
