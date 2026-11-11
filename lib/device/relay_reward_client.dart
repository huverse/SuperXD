import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/festival.dart';

// 节日抽签的自建中转实现：POST /v1/rewards/<活动>/draw，用抽奖身份签名（FestivalPass：social 实现、组合根注入，人工决策见 domain/festival.dart），
// 请求体只有近 30 天打开过的天数。超时（15 秒）、请求记录与校时后重发一次都沿用中转请求的封装；不自动重试
// （同一台抽奖设备重复抽返回同一结果，下次打开时再试）。
class RelayRewardClient implements FestivalRewardClient {
  RelayRewardClient(this._pass);
  final FestivalPass _pass;

  @override
  Future<FestivalDraw> draw(String campaign, {required String occasion, required int activeDays}) async {
    final body = await _pass.post('/v1/rewards/$campaign/draw', {'activeDays': activeDays});
    try {
      return parseFestivalDraw(body, occasion: occasion, now: DateTime.now().toUtc());
    } on FormatException catch (error, stack) {
      campusLog('[Festival] action=draw errorType=${error.runtimeType} message=${error.message}\n$stack');
      throw const FestivalException('服务器返回的格式不对');
    }
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
