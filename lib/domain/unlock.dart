import 'package:superxd/domain/app_account.dart';
import 'package:superxd/domain/rollout.dart';

// 解锁（隐藏服务与新游戏抢先玩，[人工决策-2026-11-14 20:20:18] 规则见服务端 src/modules/unlock/unlock_rules.ts）：
// 哪些项、什么条件写在灰度配置的 unlocks（RolloutUnlock）；这个账号此刻能用哪些由服务器按积分等级、买过与抽中算（UnlockState）。

class UnlockState {
  const UnlockState({required this.level, required this.open});
  // 积分等级 0–5。
  final int level;
  // 此刻能用的解锁编号（含已公开的）。
  final Set<String> open;
}

enum UnlockFailure { notSignedIn, unavailable, pointsShort, network, rateLimited, failed }

class UnlockException implements Exception {
  const UnlockException(this.failure, this.message);
  final UnlockFailure failure;
  final String message;
  @override
  String toString() => 'UnlockException($failure)';
}

// 中转端口（social 实现）：用这个应用账号的设备密钥签名。
abstract interface class UnlockClient {
  Future<UnlockState> state(AppAccountRef account);
  Future<UnlockState> buy(AppAccountRef account, String id);
}

// 页面用的端口（application 实现，组合根注入）：跟着当前的应用账号；配置或状态变了 changes 发一次。
abstract interface class UnlockAccess {
  Stream<void> get changes;
  // 配置里登记了这一项、此刻对当前账号没开（下架的也算）：游戏卡画成锁着的，隐藏的工具不显示入口。没登记的不受影响。
  bool locked(String id);
  // 锁着、没下架的那一项（卡片上写条件、给买）；没登记、已开或下架为空。
  RolloutUnlock? offer(String id);
  // 能用积分买、还没开的（积分页列出来）。
  List<RolloutUnlock> get purchasable;
  Future<void> refresh();
  // 花积分买一项，失败抛 UnlockException。
  Future<void> buy(String id);
}
