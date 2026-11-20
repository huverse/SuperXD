import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'package:superxd/domain/campus_http.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/device/signed_content.dart';

// 签名信封加 base64 的规则包（上限 256KB）也远不到 512KB；中转与 tool/cinema_rules.dart 同一上限。
const cinemaFeedResponseMaxBytes = 512 * 1024;

class CinemaFeedException implements Exception {
  const CinemaFeedException(this.message);
  final String message;
  @override
  String toString() => 'CinemaFeedException($message)';
}

// 电影院片源规则包的自建中转实现（人工决策见 lib/toolbox/cinema/cinema_service.dart 文件头）：GET /v1/app/cinema，免设备签名、不带任何标识，
// 单次 15 秒超时、不自动重试；只认验签通过的载荷（device/signed_content.dart 的 cinema 类），解析与校验在电影院自己那边（toolbox/cinema/cinema_rule.dart）。
// 中转上还没放规则包时回信封为空，按拿不到处理。
class RelayCinemaFeed {
  RelayCinemaFeed(this.baseUrl, {this.keys = trustedSigningKeys, http.Client? client, this.timeout = const Duration(seconds: 15)}) : _http = CampusHttp('cinema', client: client);
  final String baseUrl;
  final List<TrustedSigningKey> keys;
  final Duration timeout;
  final CampusHttp _http;

  Future<Uint8List> fetch() async {
    final http.Response response;
    try {
      response = await _http.send('GET', Uri.parse('$baseUrl/v1/app/cinema'), timeout: timeout, limit: cinemaFeedResponseMaxBytes);
    } catch (error, stack) {
      campusLog('[CinemaFeed] action=fetch errorType=${error.runtimeType}\n$stack');
      throw const CinemaFeedException('连不上服务器');
    }
    if (response.statusCode != 200) {
      campusLog('[CinemaFeed] action=fetch status=${response.statusCode}');
      throw CinemaFeedException('服务器回了 ${response.statusCode}');
    }
    try {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      if (body case {'version': 1, 'envelope': null}) throw const CinemaFeedException('还没有片源规则');
      if (body case {'version': 1, 'envelope': final Object envelope}) return await openSignedEnvelope(envelope, SignedContent.cinema, keys: keys);
      throw const CinemaFeedException('规则包格式不对');
    } on SignedEnvelopeException catch (error, stack) {
      campusLog('[CinemaFeed] action=fetch errorType=${error.runtimeType} reason=${error.reason}\n$stack');
      throw const CinemaFeedException('规则包没通过校验');
    } on FormatException catch (error, stack) {
      campusLog('[CinemaFeed] action=fetch errorType=${error.runtimeType} message=${error.message}\n$stack');
      throw const CinemaFeedException('规则包格式不对');
    }
  }
}
