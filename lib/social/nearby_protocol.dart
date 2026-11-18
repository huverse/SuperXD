import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:superxd/domain/campus_crypto.dart';

// 面对面私信的出现标记（人工决策见 nearby_service.dart）：开着面对面页的手机在蓝牙上给附近读它的手机这一小段，
// 好友认得出是谁、别人只看到随机字节：不带设备号与公钥，每次打开面对面页换一个随机数，路过的人没法跨次认出同一台手机。
// 布局：版本 1(1) | 随机数(8) | 好友标记(8) | 二维码标记(4)，共 21 字节，默认 MTU 下一次读完。
// 好友标记 = HMAC-SHA256(出现密钥, 随机数) 前 8 字节；出现密钥 = SHA-256(域前缀 + 自己的签名公钥)，只有加了好友（或看过二维码）的人才知道这把公钥。
// 二维码标记：正在出示二维码时 = HMAC-SHA256(SHA-256(域前缀 + 邀请种子), 随机数) 前 4 字节，扫了码的人据此在附近找到出示的那台；没在出示时是随机字节。

const presenceVersion = 1;
const presenceLength = 1 + 8 + 8 + 4;

Uint8List presenceKeyOf(List<int> signPublicKey) => Uint8List.fromList(sha256.convert([...utf8.encode('SXD1-nearby-presence\n'), ...signPublicKey]).bytes);

Uint8List _inviteKey(List<int> inviteSeed) => Uint8List.fromList(sha256.convert([...utf8.encode('SXD1-nearby-invite\n'), ...inviteSeed]).bytes);

List<int> _tag(List<int> key, List<int> nonce, int length) => Hmac(sha256, key).convert(nonce).bytes.sublist(0, length);

Uint8List buildPresence({required Uint8List presenceKey, Uint8List? inviteSeed, Uint8List? nonce}) {
  final random = nonce ?? secureRandomBytes(8);
  return Uint8List.fromList([
    presenceVersion,
    ...random,
    ..._tag(presenceKey, random, 8),
    ...(inviteSeed == null ? secureRandomBytes(4) : _tag(_inviteKey(inviteSeed), random, 4)),
  ]);
}

bool _sameBytes(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  var difference = 0;
  for (var index = 0; index < left.length; index++) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}

bool _valid(Uint8List presence) => presence.length == presenceLength && presence[0] == presenceVersion;

// 读到的出现标记是哪位好友（外部输入：长度或版本不对算不认识）；keys 是好友设备号到出现密钥，最多 500 个。
String? presenceFriend(Uint8List presence, Map<String, Uint8List> keys) {
  if (!_valid(presence)) return null;
  final nonce = presence.sublist(1, 9), tag = presence.sublist(9, 17);
  for (final entry in keys.entries) {
    if (_sameBytes(_tag(entry.value, nonce, 8), tag)) return entry.key;
  }
  return null;
}

// 这台手机是不是正在出示这张二维码。
bool presenceShows(Uint8List presence, Uint8List inviteSeed) => _valid(presence) && _sameBytes(_tag(_inviteKey(inviteSeed), presence.sublist(1, 9), 4), presence.sublist(17, 21));
