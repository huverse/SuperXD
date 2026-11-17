import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'package:superxd/domain/app_account.dart';
import 'package:superxd/domain/campus_crypto.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/festival.dart';
import 'package:superxd/social/relay_app_account.dart';
import 'package:superxd/social/relay_client.dart';
import 'package:superxd/social/social_crypto.dart';

// 节日抽签的自建中转实现（人工决策见 domain/festival.dart）：POST /v1/rewards/<活动>/draw，用这个应用账号的设备密钥签名
// （同挑战，密钥在安全存储 superxd_account 的 account.slot），请求体是近 30 天打开过的天数与要第 2 版奖品信封（seal: 2），娱乐与积分关着时另带 levels: false。
// 超时（15 秒）、请求记录与校时后重发一次都沿用 RelayClient；不自动重试（同一个人重复抽返回同一结果，下次回到前台再补抽）。
// 抽中的奖品用这台设备的 box 公钥封装、另带服务器签名（openRewardPrize），只有它打得开、验过签才揭晓。serverKeys 是受信的服务器在线签名公钥，测试换成测试钥。
class RelayRewardClient implements FestivalRewardClient {
  RelayRewardClient({required this.vault, required RelayTransport transport, this.serverKeys = relayServerKeys}) : _relay = RelayClient(transport, serverKeys: serverKeys);
  final AppAccountVault vault;
  final List<String> serverKeys;
  final RelayClient _relay;

  @override
  Future<FestivalDraw> draw(AppAccountRef account, String campaign, {required String occasion, required int activeDays, bool levels = true}) async {
    final saved = await vault.read(account.slot);
    if (saved == null) throw const FestivalNotSignedIn();
    final Map<String, Object?> body;
    try {
      body = await _relay.request(saved.identity, 'POST', '/v1/rewards/$campaign/draw', {'activeDays': activeDays, if (!levels) 'levels': false, 'seal': rewardSignedSealVersion});
    } on RelayException catch (error) {
      final eligibleAt = error.detail['eligibleAt'];
      if (error.code == RelayCode.accountTooNew && eligibleAt is int) return FestivalTooNew(DateTime.fromMillisecondsSinceEpoch(eligibleAt, isUtc: true));
      throw switch (error.code) {
        RelayCode.accountNotFound || RelayCode.unauthorized => const FestivalNotSignedIn(),
        RelayCode.network || RelayCode.timeout => const FestivalException('连不上服务器'),
        RelayCode.rateLimited => const FestivalException('请求过于频繁'),
        _ => FestivalException('服务器暂时不可用（${error.code}）'),
      };
    }
    try {
      final sealed = body['sealed'];
      final prize = body['result'] == 'won' && sealed is String
          ? await openRewardPrize(tryDecodeBase64UrlNoPad(sealed) ?? (throw const FormatException('奖品不是 base64url')), saved.identity, campaign, serverKeys: serverKeys)
          : null;
      return parseFestivalDraw(body, prize: prize, occasion: occasion, now: DateTime.now().toUtc());
    } on FormatException catch (error, stack) {
      campusLog('[Festival] action=draw errorType=${error.runtimeType} message=${error.message}\n$stack');
      throw const FestivalException('服务器返回的格式不对');
    }
  }

  // 查活动能不能领（信里的「领取」先问，人工决策见 domain/developer_note.dart 的附件）：同样用这个应用账号的设备密钥签名，娱乐与积分关着带 levels=0。
  @override
  Future<RewardStatus> status(AppAccountRef account, String campaign, {bool levels = true}) async {
    final saved = await vault.read(account.slot);
    if (saved == null) throw const FestivalNotSignedIn();
    final Map<String, Object?> body;
    try {
      body = await _relay.request(saved.identity, 'GET', '/v1/rewards/$campaign${levels ? '' : '?levels=0'}', null);
    } on RelayException catch (error) {
      throw switch (error.code) {
        RelayCode.accountNotFound || RelayCode.unauthorized => const FestivalNotSignedIn(),
        RelayCode.network || RelayCode.timeout => const FestivalException('连不上服务器'),
        RelayCode.rateLimited => const FestivalException('请求过于频繁'),
        _ => FestivalException('服务器暂时不可用（${error.code}）'),
      };
    }
    try {
      return parseRewardStatus(body);
    } on FormatException catch (error, stack) {
      campusLog('[Festival] action=status errorType=${error.runtimeType} message=${error.message}\n$stack');
      throw const FestivalException('服务器返回的格式不对');
    }
  }
}

// 活动状态是外部输入（GET /v1/rewards/<活动>，11-16 起）：state 只认那五个，时刻逐项校验。
RewardStatus parseRewardStatus(Object? json) {
  if (json case {'state': final String state, 'endsAt': final Object? endsAt, 'eligibleAt': final Object? eligibleAt}) {
    final parsed = switch (state) {
      'open' => RewardState.open,
      'drawn' => RewardState.drawn,
      'closed' => RewardState.closed,
      'ineligible' => RewardState.ineligible,
      'too_new' => RewardState.tooNew,
      _ => throw const FormatException('活动状态不认识'),
    };
    final ends = switch (endsAt) {
      null => null,
      final String text when DateTime.tryParse(text) != null && text.endsWith('Z') => DateTime.parse(text).toUtc(),
      _ => throw const FormatException('结束时刻不对'),
    };
    final eligible = switch (eligibleAt) {
      null => null,
      final int millis => DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true),
      _ => throw const FormatException('能领的时刻不对'),
    };
    if (parsed == RewardState.tooNew && eligible == null) throw const FormatException('天数不够却没给能领的时刻');
    return RewardStatus(parsed, endsAt: ends, eligibleAt: eligible);
  }
  throw const FormatException('不是活动状态');
}

// 抽签结果是外部输入：逐项校验，不合格抛 FormatException；抽中时 prize 是解开的奖品信封。
FestivalDraw parseFestivalDraw(Object? json, {required String occasion, required DateTime now, Map<String, Object?>? prize}) => switch ((json, prize)) {
  ({'result': 'closed'}, _) => const FestivalClosed(),
  ({'result': 'missed'}, _) => const FestivalMissed(),
  ({'result': 'ineligible'}, _) => const FestivalIneligible(),
  ({'result': 'won'}, {'kind': final String kind, 'content': final String content, 'note': final String note})
      when (kind == 'password' || kind == 'qrcode') && content.trim().isNotEmpty && content.length <= 1024 && note.length <= 200 =>
    FestivalWon(FestivalPrize(occasion: occasion, kind: kind == 'password' ? FestivalPrizeKind.password : FestivalPrizeKind.qrCode, content: content.trim(), note: note.trim(), wonAt: now)),
  _ => throw const FormatException('不是抽签结果'),
};

// 奖品信封（服务端 server/src/modules/reward/reward_seal.ts，共用 server/test/vectors/reward_prize_v1.json 与 reward_prize_v2.json）：中转是明文 HTTP，口令是真钱，
// 服务器用抽签设备登记的 box 公钥封装，同一网络里的人截不走。一次性 X25519 与设备的 box 密钥协商，HKDF-SHA256（盐 = 一次性公钥 + 设备公钥，
// info = SXD1-reward-prize）派生 AES-256-GCM 密钥，附加数据绑定版本、一次性公钥与「活动编号\n设备号」。
// 布局：版本(1) | 一次性公钥(32) | 随机数(12) | 密文 | GCM 标签(16) | 服务器签名(64)；明文是 {kind, content, note} 的 JSON。
// [人工决策-2026-11-17 21:24:25] 只认第 2 版（带服务器签名，用户选「只给两类关键回复加认证」）：box 公钥是公开的，第 1 版谁都能封一份，
// 同一网络里的人能把「没抽中」改成「抽中」、在应用自己的红包界面里塞钓鱼口令或二维码。先用 serverKeys 验签（原文见 social_crypto.dart 的 rewardPrizeCanonical，
// 绑定活动与这台设备），验不过不解密；版本不对、签名不对、打不开都抛 FormatException，调用方当领取失败、不显示内容。
const rewardSignedSealVersion = 2;
const _sealOverhead = 1 + 32 + 12 + 16;
const _signatureLength = 64;
final _x25519 = X25519();
final _aes = AesGcm.with256bits();
final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

Future<Map<String, Object?>> openRewardPrize(List<int> sealed, SocialIdentity identity, String campaign, {List<String> serverKeys = relayServerKeys}) async {
  if (sealed.length <= _sealOverhead + _signatureLength || sealed[0] != rewardSignedSealVersion) throw const FormatException('奖品信封格式不对');
  final body = sealed.sublist(0, sealed.length - _signatureLength), signature = sealed.sublist(sealed.length - _signatureLength);
  if (!await verifyRelaySignature(serverKeys, rewardPrizeCanonical(campaign, identity.deviceId, body), signature)) throw const FormatException('奖品不是服务器发的');
  final ephemeral = body.sublist(1, 33);
  final keyPair = await _x25519.newKeyPairFromSeed(identity.boxSeed);
  final shared = await _x25519.sharedSecretKey(keyPair: keyPair, remotePublicKey: SimplePublicKey(ephemeral, type: KeyPairType.x25519));
  final key = await _hkdf.deriveKey(secretKey: shared, nonce: [...ephemeral, ...identity.boxPublicKey], info: utf8.encode('SXD1-reward-prize'));
  final List<int> clear;
  try {
    clear = await _aes.decrypt(
      SecretBox(body.sublist(45, body.length - 16), nonce: body.sublist(33, 45), mac: Mac(body.sublist(body.length - 16))),
      secretKey: key,
      aad: [rewardSignedSealVersion, ...ephemeral, ...utf8.encode('$campaign\n${identity.deviceId}')],
    );
  } on SecretBoxAuthenticationError {
    throw const FormatException('奖品信封打不开');
  }
  final json = jsonDecode(utf8.decode(clear));
  return json is Map<String, Object?> ? json : throw const FormatException('奖品不是对象');
}
