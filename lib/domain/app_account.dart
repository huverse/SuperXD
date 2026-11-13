// 应用账号（人工决策见下面的 KingoSignInProof 与组合根）：教务账号是登录方式之一，核对时服务器代登录一次教务。

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
