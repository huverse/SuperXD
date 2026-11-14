import 'package:superxd/domain/app_account.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/festival.dart';
import 'package:superxd/social/relay_app_account.dart';
import 'package:superxd/social/relay_client.dart';

// 节日抽签的自建中转实现（人工决策见 domain/festival.dart）：POST /v1/rewards/<活动>/draw，用这个应用账号的设备密钥签名
// （同挑战，密钥在安全存储 superxd_account 的 account.slot），请求体只有近 30 天打开过的天数。超时（15 秒）、请求记录与校时后重发一次都沿用
// RelayClient；不自动重试（同一个人重复抽返回同一结果，下次回到前台再补抽）。
class RelayRewardClient implements FestivalRewardClient {
  RelayRewardClient({required this.vault, required RelayTransport transport}) : _relay = RelayClient(transport);
  final AppAccountVault vault;
  final RelayClient _relay;

  @override
  Future<FestivalDraw> draw(AppAccountRef account, String campaign, {required String occasion, required int activeDays}) async {
    final saved = await vault.read(account.slot);
    if (saved == null) throw const FestivalNotSignedIn();
    final Map<String, Object?> body;
    try {
      body = await _relay.request(saved.identity, 'POST', '/v1/rewards/$campaign/draw', {'activeDays': activeDays});
    } on RelayException catch (error) {
      throw switch (error.code) {
        RelayCode.accountNotFound || RelayCode.unauthorized => const FestivalNotSignedIn(),
        RelayCode.network || RelayCode.timeout => const FestivalException('连不上服务器'),
        RelayCode.rateLimited => const FestivalException('请求过于频繁'),
        _ => FestivalException('服务器暂时不可用（${error.code}）'),
      };
    }
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
