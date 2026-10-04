import 'dart:convert';
import 'dart:typed_data';

import 'package:superxd/social/social_crypto.dart';

const invitePrefix = 'SXD1F:';
const nicknameMaxLength = 20;

// 二维码内容：邀请号、邀请私钥种子、出示方公钥与昵称、过期时刻。
// 扫码方由此直接拿到出示方的真实公钥（当面交换，不经服务器），并用邀请私钥签出只对自己有效的凭证。
// 编码：二进制布局再转 Base45（RFC 9285，欧盟健康码同款）：只用 QR 字母数字模式的字符，同样内容比 JSON + base64 的字节模式小好几个版本，扫码更稳。
// 布局：版本 1(1) | 邀请号(16) | 邀请种子(32) | 签名公钥(32) | 加密公钥(32) | 过期毫秒(8，大端) | 昵称 UTF-8(其余)。
class InviteCode {
  const InviteCode({required this.inviteId, required this.inviteSeed, required this.owner, required this.nickname, required this.expiresAt});
  final String inviteId;
  final Uint8List inviteSeed;
  final PeerKeys owner;
  final String nickname;
  // 毫秒，服务器时间。
  final int expiresAt;

  static const _fixed = 1 + 16 + 32 + 32 + 32 + 8;

  String encode() {
    final expires = ByteData(8)..setInt64(0, expiresAt);
    return invitePrefix + base45Encode([
      1,
      ...decodeBase64UrlNoPad(inviteId, length: 16),
      ...inviteSeed,
      ...owner.signPublicKey,
      ...owner.boxPublicKey,
      ...expires.buffer.asUint8List(),
      ...utf8.encode(nickname),
    ]);
  }

  // 扫到的任意文本都是外部输入：不是本应用的二维码或格式坏了都返回 null。
  static InviteCode? decode(String text) {
    if (!text.startsWith(invitePrefix) || text.length > 1024) return null;
    final bytes = base45Decode(text.substring(invitePrefix.length));
    if (bytes == null || bytes.length <= _fixed || bytes[0] != 1) return null;
    final String nickname;
    try {
      nickname = utf8.decode(bytes.sublist(_fixed));
    } on FormatException {
      return null;
    }
    if (!validNickname(nickname)) return null;
    return InviteCode(
      inviteId: base64UrlNoPad(bytes.sublist(1, 17)),
      inviteSeed: bytes.sublist(17, 49),
      owner: PeerKeys(bytes.sublist(49, 81), bytes.sublist(81, 113)),
      nickname: nickname,
      expiresAt: ByteData.sublistView(bytes, 113, 121).getInt64(0),
    );
  }
}

// 昵称：1–20 个字符，去掉首尾空白，不含换行等控制字符。
bool validNickname(String value) => value.trim() == value && value.isNotEmpty && value.runes.length <= nicknameMaxLength && !RegExp(r'[\x00-\x1F\x7F]').hasMatch(value);

const _base45 = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ \$%*+-./:';

// RFC 9285：每 2 字节写成 3 个字符（低位在前），末尾单字节写成 2 个字符。
String base45Encode(List<int> bytes) {
  final out = StringBuffer();
  for (var index = 0; index < bytes.length; index += 2) {
    if (index + 1 < bytes.length) {
      var value = bytes[index] * 256 + bytes[index + 1];
      for (var digit = 0; digit < 3; digit++) {
        out.write(_base45[value % 45]);
        value ~/= 45;
      }
    } else {
      out..write(_base45[bytes[index] % 45])..write(_base45[bytes[index] ~/ 45]);
    }
  }
  return out.toString();
}

// 非法字符、长度或超范围的组都返回 null。
Uint8List? base45Decode(String text) {
  if (text.length % 3 == 1) return null;
  final out = <int>[];
  for (var index = 0; index < text.length; index += 3) {
    final group = text.substring(index, index + 3 > text.length ? text.length : index + 3);
    var value = 0, scale = 1;
    for (final char in group.split('')) {
      final digit = _base45.indexOf(char);
      if (digit < 0) return null;
      value += digit * scale;
      scale *= 45;
    }
    if (group.length == 3) {
      if (value > 0xFFFF) return null;
      out..add(value >> 8)..add(value & 0xFF);
    } else {
      if (value > 0xFF) return null;
      out.add(value);
    }
  }
  return Uint8List.fromList(out);
}
