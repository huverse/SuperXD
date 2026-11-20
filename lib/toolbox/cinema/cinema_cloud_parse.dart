import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'package:superxd/toolbox/cinema/cinema_http.dart';
import 'package:superxd/toolbox/cinema/cinema_models.dart';
import 'package:superxd/toolbox/cinema/cinema_rule.dart';
import 'package:superxd/toolbox/cinema/cinema_rule_engine.dart';

// 云解析（交接 03 第 5 节）：把视频网站的播放页地址交给规则包里的解析接口，回复里的地址按 cipher 解密后直接播。
// 解出来的地址带时间戳、几分钟就失效，所以只在内存里留 3 分钟、最多 32 条；「重新解析」跳过缓存。
// 输入本身就是媒体直链时不发给任何人，直接播。

class CinemaParsed {
  const CinemaParsed({required this.title, required this.type, required this.url, required this.direct});
  final String title;
  final String type;
  final String url;
  // 输入本身就是媒体直链，没经过解析接口。
  final bool direct;
}

class CinemaParseException implements Exception {
  const CinemaParseException(this.message);
  final String message;
  @override
  String toString() => 'CinemaParseException($message)';
}

class CinemaCloudParse {
  CinemaCloudParse(this._http, {DateTime Function()? now}) : _now = now ?? DateTime.now;
  final CinemaHttp _http;
  final DateTime Function() _now;
  final _cache = <String, (DateTime, CinemaParsed)>{};

  static const cacheLifetime = Duration(minutes: 3);
  static const cacheLimit = 32;

  Future<CinemaParsed> parse(CinemaParser parser, String target, {bool fresh = false}) async {
    if (cinemaMediaUrl(target)) return CinemaParsed(title: Uri.parse(target).pathSegments.lastOrNull ?? '直链', type: 'direct', url: target, direct: true);
    final key = '${parser.id}\u0000$target';
    final cached = _cache[key];
    if (!fresh && cached != null && _now().difference(cached.$1) < cacheLifetime) return cached.$2;
    final raw = await _http.text(prepareCinemaRequest(parser.request, {'url': target}), userAgent: '', referer: '', timeout: cinemaParseTimeout);
    final reply = parseCinemaParserReply(raw, parser);
    if (reply.code.trim() != parser.okCode) throw CinemaParseException('解析服务没给结果（code=${reply.code}）');
    if (reply.url.isEmpty) throw const CinemaParseException('解析服务没给地址');
    final url = parser.cipher == null ? reply.url : await decryptCinemaUrl(reply.url, parser.cipher!);
    if (!_playable(url)) throw const CinemaParseException('解析出的地址不能播放');
    // [人工决策-2026-11-19 18:07:04]（沿用懒猫交接里用户的决定）上游对不支持的地址也回「解析成功」并给一段提示影片：照样显示上游给的标题并播放，不改判失败。
    final parsed = CinemaParsed(title: reply.title, type: reply.type, url: url, direct: false);
    _cache[key] = (_now(), parsed);
    while (_cache.length > cacheLimit) {
      _cache.remove(_cache.keys.first);
    }
    return parsed;
  }

  void clear() => _cache.clear();

  // 解析接口给的地址未必带扩展名（如 view.php/xx.mp4 之外的写法），只要求 http(s) 且不带用户名密码。
  static bool _playable(String url) {
    final uri = Uri.tryParse(url);
    return uri != null && (uri.isScheme('http') || uri.isScheme('https')) && uri.host.isNotEmpty && uri.userInfo.isEmpty;
  }
}

// AES-128-CBC 加 PKCS7，key、iv 是原文字节（同前端 CryptoJS.enc.Utf8.parse 的写法，不是口令派生），密文是 base64。
Future<String> decryptCinemaUrl(String cipherText, CinemaCipher cipher) async {
  final List<int> bytes;
  try {
    bytes = base64.decode(cipherText.trim());
  } on FormatException {
    throw const CinemaParseException('解析服务给的地址解不开');
  }
  try {
    final clear = await AesCbc.with128bits(macAlgorithm: MacAlgorithm.empty).decrypt(SecretBox(bytes, nonce: cipher.iv, mac: Mac.empty), secretKey: SecretKey(cipher.key));
    return utf8.decode(clear).trim();
  } on SecretBoxPaddingError {
    throw const CinemaParseException('解析服务给的地址解不开');
  } on ArgumentError {
    // 密文长度不是 16 的倍数（对方给的不是这种密文）。
    throw const CinemaParseException('解析服务给的地址解不开');
  } on FormatException {
    throw const CinemaParseException('解析服务给的地址解不开');
  }
}
