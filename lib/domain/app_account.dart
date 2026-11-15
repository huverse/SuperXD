import 'package:superxd/domain/campus_crypto.dart';

// 应用账号（人工决策见下面几条与 application/app_accounts.dart）。

// [人工决策-2026-11-15 16:40:33] 自己的账号体系（学校挡了中转的 IP、教务又是明文 http，服务器核实不了学号；用户说「别依赖教务系统账号了」）：
// 用户名加密码（用户选，不收手机号与邮箱）；忘了密码用注册时给的恢复码重设，或在登录着的手机上直接改（用户选，不做人工找回）；
// 应用账号与教务各管各的（用户选，取代 11-13 的「跟着教务走」）；11-13 起用教务核对登录的老账号全部重新注册（用户选）。
// 密码与恢复码在本机用中转公钥封装后才发出（social/account_seal.dart，中转是明文 HTTP），服务器只存 scrypt 哈希；恢复码在本机生成，原文只给用户看一次。
// 11-13 的中转代登录教务（口令摘要）与 11-15 的设备核对、3 天找回都作废、删除。规则在服务端 server/src/modules/account/account.service.ts。

// 一个登录着的应用账号在这台设备上的把手：账号号（灰度分桶用）与那把设备密钥在安全存储里的位置 slot。
// [人工决策-2026-11-14 16:47:34] 第 4 阶段用户要求「留好后路，以后不一定会锁死绑定教务」：用到应用账号的功能（挑战、节日抽奖、诊断包、私信）
// 只认这个把手，不认它是用什么方式登录的；11-15 换成自己的账号体系时这些功能果然不用改。
class AppAccountRef {
  const AppAccountRef({required this.accountId, required this.slot});
  final String accountId;
  final String slot;

  @override
  bool operator ==(Object other) => other is AppAccountRef && other.accountId == accountId && other.slot == slot;
  @override
  int get hashCode => Object.hash(accountId, slot);
}

// 登录着的应用账号：把手与用户名（用户名记在本机，账号页不联网也能显示）。
class AppAccountSession {
  const AppAccountSession({required this.account, required this.username});
  final AppAccountRef account;
  final String username;
}

// 用户名：3–20 位字母、数字或下划线，不分大小写（服务器存小写，这里也按小写比）。
final _usernamePattern = RegExp(r'^[a-z0-9_]{3,20}$');
String normalizeAppUsername(String raw) => raw.trim().toLowerCase();
bool validAppUsername(String raw) => _usernamePattern.hasMatch(normalizeAppUsername(raw));

// 密码 8–64 个字符（按字符数，不按字节）。
const appPasswordMin = 8, appPasswordMax = 64;
bool validAppPassword(String password) => password.runes.length >= appPasswordMin && password.runes.length <= appPasswordMax;

// 恢复码：本机生成 15 字节随机数，写成 24 位 Crockford base32（去掉 I、L、O、U），每 4 位一组给人看；交给服务器的是不带分隔符的大写写法。
const _crockford = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

String generateRecoveryCode() {
  final bytes = secureRandomBytes(15);
  final out = StringBuffer();
  var buffer = 0, bits = 0;
  for (final byte in bytes) {
    buffer = (buffer << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      out.write(_crockford[(buffer >> bits) & 31]);
    }
  }
  return out.toString();
}

String formatRecoveryCode(String code) => [for (var start = 0; start < code.length; start += 4) code.substring(start, (start + 4).clamp(0, code.length))].join('-');

// 用户输入的恢复码：去掉空白与分隔符、转大写，O 当 0、I 与 L 当 1（Crockford 的容错读法）；不像恢复码返回 null。
String? normalizeRecoveryCode(String raw) {
  final code = raw.toUpperCase().replaceAll(RegExp(r'[\s-]'), '').replaceAll('O', '0').replaceAll(RegExp('[IL]'), '1');
  return RegExp(r'^[0-9A-HJKMNP-TV-Z]{24}$').hasMatch(code) ? code : null;
}

// 扫码登录的票据（新设备出示）：二维码里是 payload，另把 6 位核对码显示出来给已登录的手机对照。
class AppAccountJoin {
  const AppAccountJoin({required this.ticketId, required this.code, required this.expiresAt});
  final String ticketId;
  final String code;
  final DateTime expiresAt;

  static const _prefix = 'superxd-join:';
  String get payload => '$_prefix$ticketId:$code';

  // 扫到的二维码：不是本应用的登录码返回 null（扫码页据此提示）。
  static ({String ticketId, String code})? parse(String raw) {
    final match = RegExp(r'^superxd-join:([A-Za-z0-9_-]{22}):(\d{6})$').firstMatch(raw.trim());
    return match == null ? null : (ticketId: match.group(1)!, code: match.group(2)!);
  }
}

class AppAccountSummary {
  const AppAccountSummary({required this.accountId, required this.username, required this.deviceCount, required this.createdAt});
  final String accountId;
  final String username;
  final int deviceCount;
  final DateTime createdAt;
}

// 中转回的失败：message 给用户看；notSignedIn 是这把设备密钥已不属于任何账号（账号在别处注销、被清理），本机记录随之作废；
// credentialsInvalid 是用户名、密码或恢复码不对（服务器不说是哪一项）；joinExpired 是扫码登录的二维码已过期或不对。
enum AppAccountFailure { notSignedIn, usernameTaken, credentialsInvalid, joinExpired, network, rateLimited, failed }

class AppAccountException implements Exception {
  const AppAccountException(this.failure, this.message);
  final AppAccountFailure failure;
  final String message;
  @override
  String toString() => 'AppAccountException($failure)';
}

// 应用账号的中转端口（social 实现）：这台设备一个应用账号、一把设备密钥，存在安全存储。
abstract interface class AppAccountClient {
  // 本机记着的应用账号，没登录为空；不联网。
  Future<AppAccountSession?> accountOf();
  // 11-15 以前每个教务账号一把的旧密钥（老账号全部重新注册）：删掉本机记录并返回它们的把手（组合根接着清掉那些账号的本机私信）。不联网。
  Future<List<AppAccountRef>> dropLegacy();
  // 注册：成功后本机记下账号号与设备密钥。recoveryCode 是本机生成、给用户抄下的恢复码。
  Future<AppAccountSession> register(String username, String password, String recoveryCode);
  Future<AppAccountSession> login(String username, String password);
  // 忘了密码：凭恢复码设新密码并换成新的恢复码，这台设备随之登录。
  Future<AppAccountSession> recover(String username, String recoveryCode, String password, String newRecoveryCode);
  // 登录着改密码、换恢复码。
  Future<void> changePassword(String password);
  Future<void> changeRecoveryCode(String recoveryCode);
  // 扫码登录，新设备这一侧：发一张票据；问批准了没有（批准了本机记下账号号并返回把手，还在等返回 null，过期抛 joinExpired）。
  Future<AppAccountJoin> startJoin();
  Future<AppAccountSession?> joinState(AppAccountJoin join);
  // 登录着的设备批准扫到的登录码。
  Future<void> approveJoin(String payload);
  // 联网看账号，顺带让服务器记最后活跃；notSignedIn 时本机记录已删。
  Future<AppAccountSummary> summary();
  // 退出：删服务端这把设备密钥（连带登记），再删本机记录；服务端已不认时照样删本机。
  Future<void> signOut();
  // 注销账号：服务端删账号（全部设备的登记与账号下的数据），再退出。
  Future<void> delete();
}
