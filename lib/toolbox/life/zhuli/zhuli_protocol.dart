import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

// 住理生活（com.whxinna.userplatform 3.12.8）的请求协议（集成资料 docs/住理生活_接入集成文档.md 第二节，11-22 用两个授权测试账号实测过）：
// 全部业务都是 GET 加签名。平台端（登录、图形验证码、找回密码）在 pm.whxinna.com、用 App 里写死的密钥；
// 业务端在登录给的 server_addr、用每次登录都变的 session_secret，另带 user_id、identitycode、pid、appid 四个公共参数。

const zhuliPlatformBase = 'https://pm.whxinna.com';
// 平台端的签名密钥（原 App 前端写死的常量，不是谁的凭据）。
const zhuliPlatformKey = '6d5dbb85b949447a95ff8fda9a9b759b';
// 登录时报的 App 版本，同原 App。
const zhuliAppVersion = '3.12.8';

final _random = Random.secure();
const _nonceAlphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';

// 32 位随机字母数字（同原 App 的 noncestr）。
String zhuliNonce() => String.fromCharCodes(List.generate(32, (_) => _nonceAlphabet.codeUnitAt(_random.nextInt(_nonceAlphabet.length))));

// 原 App 的 base64：标准 base64 再把 + 换成 -、/ 换成 _，保留 = 填充。
String zhuliBase64(String text) => base64.encode(utf8.encode(text)).replaceAll('+', '-').replaceAll('/', '_');

// 一个参数值按 JS 的 JSON.stringify 写（签名按它算）：整数值的小数写成整数（1.0 → 1），布尔是 true、false，字符串带引号与转义。
String zhuliJsValue(Object? value) => switch (value) {
  null => 'null',
  final double number when number.isFinite && number == number.truncateToDouble() => number.toInt().toString(),
  final num number => number.toString(),
  final bool flag => '$flag',
  _ => jsonEncode(value),
};

// 签名：去掉空值，按键排序写成 k=JSON.stringify(v) 用 & 连起来，去掉所有双引号与空格，接上 &key=密钥取 MD5 转大写。
String zhuliSign(Map<String, Object?> params, String key) {
  final names = [for (final entry in params.entries) if (entry.value != null && entry.value != '') entry.key]..sort();
  final text = names.map((name) => '$name=${zhuliJsValue(params[name])}').join('&').replaceAll('"', '').replaceAll(' ', '');
  return md5.convert(utf8.encode('$text&key=$key')).toString().toUpperCase();
}

// 一次请求的查询参数：对象与数组参数换成 base64_<名>（JSON 再 base64），加时刻、随机串与公共参数后签名；值一律转成字符串发出。
Map<String, String> zhuliQuery(Map<String, Object?> params, {required String key, Map<String, Object> common = const {}, DateTime? now, String? nonce}) {
  final signed = <String, Object?>{};
  for (final MapEntry(key: name, :value) in params.entries) {
    if (value is Map || value is List) {
      signed['base64_$name'] = zhuliBase64(jsonEncode(value));
    } else {
      signed[name] = value;
    }
  }
  signed['timestamp'] = '${(now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000}';
  signed['noncestr'] = nonce ?? zhuliNonce();
  signed.addAll(common);
  signed['sign'] = zhuliSign(signed, key);
  return {for (final MapEntry(key: name, :value) in signed.entries) if (value != null) name: value is double || value is bool ? zhuliJsValue(value) : '$value'};
}

// 蓝牙命令帧固定 20 字节（命令类型在第 3 个字节），收发都按十六进制串。
const zhuliFrameLength = 20;

final _hexFrame = RegExp(r'^(?:[0-9A-Fa-f]{2})+$');

// 回复的 data 是字符串时是 base64（- 与 _ 换回 + 与 /、补齐 =）包着的 JSON；外部输入，解不开抛 FormatException。
// 例外是蓝牙命令帧：原 App 把这几个接口的 data 原样写给设备，是十六进制串（JSON 的 base64 总有十六进制以外的字符，不会混）。
Object? zhuliDecodeData(Object? data) {
  if (data is! String) return data;
  if (_hexFrame.hasMatch(data)) return data;
  final normalized = data.replaceAll('-', '+').replaceAll('_', '/');
  return jsonDecode(utf8.decode(base64.decode(normalized.padRight((normalized.length + 3) ~/ 4 * 4, '='))));
}
