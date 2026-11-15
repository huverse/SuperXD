import 'package:superxd/domain/account.dart';

// 应用账号（人工决策见下面几条与 application/app_accounts.dart）：教务学号是账号的身份，11-15 起由手机自己登录教务核对（设备核对）。

// [人工决策-2026-11-15 15:04:27] 学校把中转的 IP 整个挡了、确定不会解封，也不加服务器：用户选「设备核对 + 风险规则」，取代下面 11-13 的「服务器代登录一次」。
// 手机自己登录教务（本来就要登），把教务确认的学号交给中转，口令摘要不再出手机；学号照旧只存带服务器密钥的哈希。服务器验不了手机报的学号，
// 所以按风险分级：学号没有账号就新建；已有账号的要已登录的设备扫码授权（不能凭设备核对接管）；中转按设备、来源、全局与学号限流；节日红包只给建立满 7 天的账号。
// [人工决策-2026-11-15 15:13:06] 找回（用户选「退出了直接登回，丢了走等待期」）：账号的设备都退出了，设备核对直接登回；
// 还有设备登着（丢了手机、重装没退出）就提交找回申请，等 3 天，账号的设备打开应用时提醒、可以拒绝或批准，没人拒绝就生效；
// 同时有别的设备在申请就都不生效。规则在服务端 server/src/modules/account/account.service.ts 的 deviceSignIn。

// [人工决策-2026-11-13 22:06:22]（11-15 起被上面的设备核对取代，登录教务仍用 KingoSignInProof 拼参数）教务会话绑 IP 且同一账号只有一个会话（11-13 用授权测试账号实测：中转拿手机的会话去读，教务当游客并把整份会话作废；
// 中转用密码登录会把手机先登的会话挤掉），原定的「把会话交给中转核对」不可行。用户选「服务器代登录一次，同时留好后路」：
// 客户端只交教务登录要用的口令摘要（hexMd5(明文) 与几项强度旁证，见 edu/login_rules.dart 的 kingoSignInProof），用中转公钥加密后发出；
// 中转登录一次、读身份页取学号后丢弃，学号只存带服务器密钥的哈希；客户端紧接着自己重登。核对办法在服务端是可替换的登录方式，账号体系不感知。
// 摘要对这所学校的教务等同密码（拿到它就能登录），但不是明文：别的网站上同一个密码不会因此暴露（弱密码仍可能被字典反推）。
class KingoSignInProof {
  const KingoSignInProof({required this.account, required this.passwordDigest, required this.expression, required this.length, required this.userzh, required this.policy});
  final String account;
  final String passwordDigest;
  final String expression;
  final String length;
  final String userzh;
  final String policy;

  Map<String, String> toJson() => {'account': account, 'passwordDigest': passwordDigest, 'expression': expression, 'length': length, 'userzh': userzh, 'policy': policy};
}

// 一个登录着的应用账号在这台设备上的把手：账号号（灰度分桶用）与那把设备密钥在安全存储里的位置 slot。
// [人工决策-2026-11-14 16:47:34] 第 4 阶段用户要求「留好后路，以后不一定会锁死绑定教务」：用到应用账号的功能（挑战、节日抽奖、诊断包、私信）
// 只认这个把手，不认它是用什么方式登录的、跟着哪个教务账号；现在「每个教务账号一个应用账号」（slot 由教务身份算出）只是 AppAccountClient 实现
// 与组合根的规则（application/app_accounts.dart），以后加别的登录方式或不再跟着教务切换，这些功能不用改。
class AppAccountRef {
  const AppAccountRef({required this.accountId, required this.slot});
  final String accountId;
  final String slot;

  @override
  bool operator ==(Object other) => other is AppAccountRef && other.accountId == accountId && other.slot == slot;
  @override
  int get hashCode => Object.hash(accountId, slot);
}

// 设备核对这一步的结果（人工决策见上方 11-15 那两条）：登录成功（新建或所有设备都退出后登回），或这个学号已有应用账号、还有设备登着，
// 要用已登录的设备扫码授权或申请找回。
sealed class AppAccountStep {
  const AppAccountStep();
}

final class AppAccountSignedIn extends AppAccountStep {
  const AppAccountSignedIn({required this.account, required this.created});
  final AppAccountRef account;
  final bool created;
}

final class AppAccountExists extends AppAccountStep {
  const AppAccountExists();
}

// 扫码授权的票据（新设备出示）：二维码里是 payload，另把 6 位核对码显示出来给旧设备对照。
class AppAccountJoin {
  const AppAccountJoin({required this.ticketId, required this.code, required this.expiresAt});
  final String ticketId;
  final String code;
  final DateTime expiresAt;

  static const _prefix = 'superxd-join:';
  String get payload => '$_prefix$ticketId:$code';

  // 扫到的二维码：不是本应用的授权码返回 null（扫码页据此提示）。
  static ({String ticketId, String code})? parse(String raw) {
    final match = RegExp(r'^superxd-join:([A-Za-z0-9_-]{22}):(\d{6})$').firstMatch(raw.trim());
    return match == null ? null : (ticketId: match.group(1)!, code: match.group(2)!);
  }
}

// 找回申请：pending 等待中（grantAt 起没人拒绝就生效）、granted 已生效、denied 被账号的设备拒绝、conflict 同时有别的设备在申请、为安全不生效。
enum AppAccountRecoveryState { pending, granted, denied, conflict }

class AppAccountRecovery {
  const AppAccountRecovery({required this.id, required this.state, required this.grantAt});
  final String id;
  final AppAccountRecoveryState state;
  final DateTime grantAt;
}

// 别的设备提交、等待中的找回申请（账号的设备打开应用时提醒，可拒绝或批准）。
class AppAccountPendingRecovery {
  const AppAccountPendingRecovery({required this.id, required this.createdAt, required this.grantAt});
  final String id;
  final DateTime createdAt;
  final DateTime grantAt;
}

class AppAccountSummary {
  const AppAccountSummary({required this.accountId, required this.providers, required this.deviceCount, required this.createdAt, this.recoveries = const []});
  final String accountId;
  final List<String> providers;
  final int deviceCount;
  final DateTime createdAt;
  final List<AppAccountPendingRecovery> recoveries;
}

// 中转回的失败：message 给用户看；notSignedIn 是这把设备密钥已不属于任何账号（账号在别处注销、被清理或从没登录成功），本机记录随之作废；
// joinExpired 是二维码或找回申请已过期、处理过或不对；joinMismatch 是批准的设备登的不是同一个学号的应用账号。
enum AppAccountFailure { notSignedIn, joinExpired, joinMismatch, network, rateLimited, failed }

class AppAccountException implements Exception {
  const AppAccountException(this.failure, this.message);
  final AppAccountFailure failure;
  final String message;
  @override
  String toString() => 'AppAccountException($failure)';
}

// 应用账号的中转端口（social 实现）：每个教务账号一个应用账号，各用一把设备密钥，按教务身份分开存在安全存储；
// 设备核对之后学号已有账号时，这把密钥先存成「等待中」，扫码授权或找回生效后补上账号号（找回要等几天，重启应用也接着用这把）。
abstract interface class AppAccountClient {
  // 本机记着的这个教务账号的应用账号，没登录（含等待中）为空；不联网。
  Future<AppAccountRef?> accountOf(AccountIdentity identity);
  // 设备核对：把教务确认的学号交给中转（手机自己登录了教务）。成功后本机记下账号号与设备密钥；已有账号时记下等待中的密钥。
  Future<AppAccountStep> signInWithDevice(AccountIdentity identity);
  // 扫码授权，新设备这一侧：发一张票据（要先设备核对过、有等待中的密钥）。
  Future<AppAccountJoin> startJoin(AccountIdentity identity);
  // 新设备问票据批准了没有：批准了本机记下账号号并返回把手，还在等返回 null，过期抛 joinExpired。
  Future<AppAccountRef?> joinState(AccountIdentity identity, AppAccountJoin join);
  // 已登录的设备批准扫到的授权码。
  Future<void> approveJoin(AccountIdentity identity, String payload);
  // 提交找回申请（要先设备核对过、有等待中的密钥）。
  Future<AppAccountRecovery> requestRecovery(AccountIdentity identity);
  // 本机等待中的找回申请的现状（联网）：生效了本机记下账号号；没有申请返回 null。
  Future<AppAccountRecovery?> recoveryOf(AccountIdentity identity);
  // 账号的设备拒绝或批准一条找回申请。
  Future<void> decideRecovery(AccountIdentity identity, String recoveryId, {required bool approve});
  // 联网看账号，顺带让服务器记最后活跃、带回等待中的找回申请；notSignedIn 时本机记录已删。
  Future<AppAccountSummary> summary(AccountIdentity identity);
  // 退出：删服务端这把设备密钥（连带登记），再删本机记录（含等待中的）；服务端已不认时照样删本机。
  Future<void> signOut(AccountIdentity identity);
  // 注销账号：服务端删账号（登录方式与全部设备的登记），再退出。
  Future<void> delete(AccountIdentity identity);
}
