import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/festival.dart';

// 响应只有结果与一份奖品（内容最多 1024 字），中转不会超过这么大；超过就当异常，不往下读。
const festivalResponseMaxBytes = 8 * 1024;

// 节日抽签的自建中转实现：POST /v1/rewards/<活动>/draw，免签名；只发参与号与近 30 天打开过的天数（人工决策见 domain/festival.dart），
// 单次 15 秒超时、不自动重试（同一参与号重复抽返回同一结果，下次打开时再试）。
class RelayRewardClient implements FestivalRewardClient {
  RelayRewardClient(this.baseUrl, {http.Client? client, this.timeout = const Duration(seconds: 15)}) : _client = client ?? http.Client();
  final String baseUrl;
  final Duration timeout;
  final http.Client _client;

  @override
  Future<FestivalDraw> draw(String campaign, {required String occasion, required String participant, required int activeDays}) async {
    final uri = Uri.parse('$baseUrl/v1/rewards/$campaign/draw');
    final int status;
    final List<int> body;
    final watch = Stopwatch()..start();
    try {
      final request = http.Request('POST', uri)
        ..headers['content-type'] = 'application/json'
        ..body = jsonEncode({'participant': participant, 'activeDays': activeDays});
      final response = await _client.send(request).timeout(timeout);
      status = response.statusCode;
      body = await _read(response.stream).timeout(timeout);
      campusRequestLog('festival', 'POST', uri, status: status, elapsed: watch.elapsed, bytes: body.length);
    } on FestivalException {
      rethrow;
    } catch (error, stack) {
      campusRequestLog('festival', 'POST', uri, elapsed: watch.elapsed, error: error is TimeoutException ? 'timeout' : error.runtimeType.toString());
      campusLog('[Festival] action=draw errorType=${error.runtimeType}\n$stack');
      throw const FestivalException('连不上服务器');
    }
    if (status != 200) {
      campusLog('[Festival] action=draw status=$status');
      throw const FestivalException('服务器暂时不可用');
    }
    try {
      return parseFestivalDraw(jsonDecode(utf8.decode(body)), occasion: occasion, now: DateTime.now().toUtc());
    } on FormatException catch (error, stack) {
      campusLog('[Festival] action=draw errorType=${error.runtimeType} message=${error.message}\n$stack');
      throw const FestivalException('服务器返回的格式不对');
    }
  }

  Future<List<int>> _read(Stream<List<int>> stream) async {
    final bytes = <int>[];
    await for (final chunk in stream) {
      bytes.addAll(chunk);
      if (bytes.length > festivalResponseMaxBytes) throw const FestivalException('服务器暂时不可用');
    }
    return bytes;
  }
}

// 抽签结果是外部输入：逐项校验，不合格抛 FormatException。
FestivalDraw parseFestivalDraw(Object? json, {required String occasion, required DateTime now}) => switch (json) {
  {'result': 'closed'} => const FestivalClosed(),
  {'result': 'missed'} => const FestivalMissed(),
  {'result': 'won', 'prize': {'kind': final String kind, 'content': final String content, 'note': final String note}}
      when (kind == 'password' || kind == 'qrcode') && content.trim().isNotEmpty && content.length <= 1024 && note.length <= 200 =>
    FestivalWon(FestivalPrize(occasion: occasion, kind: kind == 'password' ? FestivalPrizeKind.password : FestivalPrizeKind.qrCode, content: content.trim(), note: note.trim(), wonAt: now)),
  _ => throw const FormatException('不是抽签结果'),
};
