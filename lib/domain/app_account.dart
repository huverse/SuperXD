import 'package:superxd/domain/account.dart';
import 'package:superxd/domain/campus_gateway.dart';

// 应用账号（人工决策见下面的 KingoSignInProof 与 application/app_accounts.dart）：教务账号是登录方式之一，核对时服务器代登录一次教务。

// [人工决策-2026-11-13 22:06:22] 教务会话绑 IP 且同一账号只有一个会话（11-13 用授权测试账号实测：中转拿手机的会话去读，教务当游客并把整份会话作废；
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

// 登录这一步的结果：登录成功（账号号，客户端拿它做灰度分桶）或要先答验证码。
sealed class AppAccountStep {
  const AppAccountStep();
}

final class AppAccountSignedIn extends AppAccountStep {
  const AppAccountSignedIn({required this.accountId, required this.created});
  final String accountId;
  final bool created;
}

final class AppAccountCaptcha extends AppAccountStep {
  const AppAccountCaptcha(this.captcha);
  final CaptchaView captcha;
}

class AppAccountSummary {
  const AppAccountSummary({required this.accountId, required this.providers, required this.deviceCount, required this.createdAt});
  final String accountId;
  final List<String> providers;
  final int deviceCount;
  final DateTime createdAt;
}

// 中转回的失败：message 给用户看；notSignedIn 是这把设备密钥已不属于任何账号（账号在别处注销、被清理或从没登录成功），本机记录随之作废。
enum AppAccountFailure { rejected, captchaExpired, upstream, notSignedIn, network, rateLimited, failed }

class AppAccountException implements Exception {
  const AppAccountException(this.failure, this.message);
  final AppAccountFailure failure;
  final String message;
  @override
  String toString() => 'AppAccountException($failure)';
}

// 应用账号的中转端口（social 实现）：每个教务账号一个应用账号，各用一把设备密钥，按教务身份分开存在安全存储；
// 要验证码时这一次的设备密钥与挑战号留在实现里，答题时接着用。
abstract interface class AppAccountClient {
  // 本机记着的账号号，没登录为空；不联网。
  Future<String?> accountOf(AccountIdentity identity);
  // 用教务口令摘要登录；captcha 不为空时是答上一步的验证码。成功后本机记下账号号与设备密钥。
  Future<AppAccountStep> signInWithKingo(AccountIdentity identity, KingoSignInProof proof, {String? captcha});
  // 放弃这次没答完的验证码（丢掉留着的设备密钥与挑战号）。
  void abandon(AccountIdentity identity);
  // 联网看账号，顺带让服务器记最后活跃；notSignedIn 时本机记录已删。
  Future<AppAccountSummary> summary(AccountIdentity identity);
  // 退出：删服务端这把设备密钥（连带登记），再删本机记录；服务端已不认时照样删本机。
  Future<void> signOut(AccountIdentity identity);
  // 注销账号：服务端删账号（登录方式与全部设备的登记），再退出。
  Future<void> delete(AccountIdentity identity);
}
