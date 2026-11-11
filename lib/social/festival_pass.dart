import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:superxd/domain/festival.dart';
import 'package:superxd/social/identity_vault.dart';
import 'package:superxd/social/relay_client.dart';
import 'package:superxd/social/social_crypto.dart';

// 抽奖身份的系统安全存储：单独的命名空间，与私信身份（superxd_social）分开、互不关联；同样排除出安卓云备份与设备迁移
// （backup_rules.xml、data_extraction_rules.xml），iOS 上仅本机级别、新装后第一次启动清掉（ios/Runner/DeviceOnlyData.swift）。
const festivalPassStorage = FlutterSecureStorage(
  aOptions: AndroidOptions(storageNamespace: 'superxd_reward', resetOnError: false),
  iOptions: IOSOptions(accountName: 'superxd_reward', accessibility: KeychainAccessibility.first_unlock_this_device),
);

// 节日抽奖身份 FestivalPass 的中转实现（人工决策见 domain/festival.dart 与 server/src/modules/reward/reward_odds.ts）：
// 一对与私信身份同格式的密钥（Ed25519 签名加 X25519 加密；后者只因协议 v1 的设备登记要求两把公钥才生成，不用），存进 festivalPassStorage；
// 登记、签名请求（含校时后重发一次）与删除都复用私信的 RelayClient，不另写一份协议。中转那边它只是一台没有好友与信箱的设备。
// 什么时候生成、登记与删除由 application/festivals.dart 决定。
class RelayFestivalPass implements FestivalPass {
  RelayFestivalPass({required this.vault, required RelayTransport transport}) : _relay = RelayClient(transport);
  final IdentityVault vault;
  final RelayClient _relay;

  @override
  Future<void> enroll() async {
    final identity = await vault.read() ?? await _create();
    await _relayed(() => _relay.register(identity));
  }

  Future<SocialIdentity> _create() async {
    final created = await SocialIdentity.generate();
    await vault.write(created);
    return created;
  }

  @override
  Future<Map<String, Object?>> post(String path, Map<String, Object?> payload) async {
    final identity = await vault.read();
    if (identity == null) throw const FestivalNotEnrolled();
    return _relayed(() => _relay.request(identity, 'POST', path, payload));
  }

  @override
  Future<void> retire() async {
    final identity = await vault.read();
    if (identity == null) return;
    try {
      await _relayed(() => _relay.deleteDevice(identity));
    } on FestivalNotEnrolled {
      // 中转已经不认这台设备（从没登记成功，或 400 天不活跃被清掉）：没有可删的，照样删本机密钥。
    }
    await vault.delete();
  }

  // 中转的错误码换成节日的异常（application 与 device 不认 social 的错误码）：不认这台设备算没登记，其余按连不上、太频繁、服务器出错给原因。
  // 断网与超时的原始异常与堆栈已由传输层记进日志。
  static Future<T> _relayed<T>(Future<T> Function() send) async {
    try {
      return await send();
    } on RelayException catch (error) {
      throw switch (error.code) {
        RelayCode.unauthorized => const FestivalNotEnrolled(),
        RelayCode.network || RelayCode.timeout => const FestivalException('连不上服务器'),
        RelayCode.rateLimited => const FestivalException('请求过于频繁'),
        _ => FestivalException('服务器暂时不可用（${error.code}）'),
      };
    }
  }
}
