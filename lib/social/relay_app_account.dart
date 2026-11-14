import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:superxd/domain/account.dart';
import 'package:superxd/domain/app_account.dart';
import 'package:superxd/domain/campus_crypto.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/social/account_seal.dart';
import 'package:superxd/social/relay_client.dart';
import 'package:superxd/social/social_crypto.dart';

// 应用账号设备密钥的系统安全存储：单独的命名空间，与私信身份互不关联；同样排除出安卓云备份与设备迁移
// （backup_rules.xml、data_extraction_rules.xml），iOS 上仅本机级别、新装后第一次启动清掉（ios/Runner/DeviceOnlyData.swift）。
const appAccountStorage = FlutterSecureStorage(
  aOptions: AndroidOptions(storageNamespace: 'superxd_account', resetOnError: false),
  iOptions: IOSOptions(accountName: 'superxd_account', accessibility: KeychainAccessibility.first_unlock_this_device),
);

// 一个应用账号在本机的记录：设备密钥（同私信身份的格式）与账号号。
class AppAccountKey {
  const AppAccountKey({required this.identity, required this.accountId});
  final SocialIdentity identity;
  final String accountId;
}

abstract interface class AppAccountVault {
  Future<AppAccountKey?> read(String slot);
  Future<void> write(String slot, AppAccountKey key);
  Future<void> delete(String slot);
}

class SecureAppAccountVault implements AppAccountVault {
  const SecureAppAccountVault([this._storage = appAccountStorage]);
  final FlutterSecureStorage _storage;

  @override
  Future<AppAccountKey?> read(String slot) async {
    final raw = await _storage.read(key: slot);
    if (raw == null) return null;
    final data = jsonDecode(raw);
    if (data is! Map || data['version'] != 1 || data['sign'] is! String || data['box'] is! String || data['accountId'] is! String) throw const FormatException('保存的应用账号不可用');
    return AppAccountKey(identity: await SocialIdentity.fromSeeds(decodeBase64UrlNoPad(data['sign'] as String, length: 32), decodeBase64UrlNoPad(data['box'] as String, length: 32)), accountId: data['accountId'] as String);
  }

  @override
  Future<void> write(String slot, AppAccountKey key) => _storage.write(
    key: slot,
    value: jsonEncode({'version': 1, 'sign': base64UrlNoPad(key.identity.signSeed), 'box': base64UrlNoPad(key.identity.boxSeed), 'accountId': key.accountId}),
  );

  @override
  Future<void> delete(String slot) => _storage.delete(key: slot);
}

class MemoryAppAccountVault implements AppAccountVault {
  final records = <String, AppAccountKey>{};
  @override
  Future<AppAccountKey?> read(String slot) async => records[slot];
  @override
  Future<void> write(String slot, AppAccountKey key) async => records[slot] = key;
  @override
  Future<void> delete(String slot) async => records.remove(slot);
}

// 安全存储里的键：教务身份的哈希，存储里不出现学号。
String appAccountSlot(AccountIdentity identity) => 'account.${base64UrlNoPad(sha256.convert(utf8.encode('SXD1-app-account\n${identity.source}\n${identity.loginId}')).bytes.sublist(0, 16))}';

final _accountIdPattern = RegExp(r'^[A-Za-z0-9_-]{22}$');

// 应用账号端口的中转实现（人工决策见 domain/app_account.dart，协议见 server/README.md「应用账号」）：
// 签名请求、校时重发一次都复用私信的 RelayClient；每个教务账号一把单独的设备密钥，登录成功才存进安全存储。
class RelayAppAccountClient implements AppAccountClient {
  RelayAppAccountClient({required this.vault, required RelayTransport transport, List<int>? sealKey}) : _relay = RelayClient(transport), _sealKey = sealKey ?? decodeBase64UrlNoPad(accountSealKey, length: 32);
  final AppAccountVault vault;
  final RelayClient _relay;
  final List<int> _sealKey;
  // 要验证码时这一次的设备密钥与挑战号（挑战号只认发起的那把密钥），答题时接着用。
  final _pending = <String, ({SocialIdentity key, String challengeId})>{};

  // 中转代登录教务整次最多 40 秒（服务端 relay_limits.ts 的 kingoSignInDeadlineMs），这里多等一点。
  static const signInTimeout = Duration(seconds: 50);

  @override
  Future<AppAccountRef?> accountOf(AccountIdentity identity) async {
    final slot = appAccountSlot(identity);
    final saved = await vault.read(slot);
    return saved == null ? null : AppAccountRef(accountId: saved.accountId, slot: slot);
  }

  @override
  Future<AppAccountStep> signInWithKingo(AccountIdentity identity, KingoSignInProof proof, {String? captcha}) async {
    final slot = appAccountSlot(identity);
    final pending = captcha == null ? null : _pending[slot];
    _pending.remove(slot);
    if (captcha != null && pending == null) throw const AppAccountException(AppAccountFailure.captchaExpired, '验证码已过期，请重新登录');
    final key = pending?.key ?? await SocialIdentity.generate();
    final sealed = await sealAccountProof(proof, key.deviceId, _sealKey);
    final body = await _relayed(() => _relay.request(key, 'POST', '/v1/account/sign-in/kingo', {
      'signPublicKey': base64UrlNoPad(key.signPublicKey),
      'boxPublicKey': base64UrlNoPad(key.boxPublicKey),
      'sealed': base64UrlNoPad(sealed),
      'challengeId': ?pending?.challengeId,
      'captcha': ?captcha,
    }, signInTimeout));
    final status = body['status'];
    if (body['captcha'] case final Map<Object?, Object?> raw when status == 'captcha') {
      final challengeId = raw['challengeId'], image = raw['image'], contentType = raw['contentType'], hint = raw['hint'];
      if (challengeId is String && _accountIdPattern.hasMatch(challengeId) && image is String && contentType is String && contentType.startsWith('image/') && hint is String && _isBase64(image)) {
        _pending[slot] = (key: key, challengeId: challengeId);
        return AppAccountCaptcha(CaptchaView(prompt: '请输入图中的验证码', hint: hint, contentType: contentType, imageBase64: image));
      }
    }
    if (body['account'] case final Map<Object?, Object?> raw when status == 'signedIn') {
      final accountId = raw['accountId'], created = raw['created'];
      if (accountId is String && _accountIdPattern.hasMatch(accountId) && created is bool) {
        await vault.write(slot, AppAccountKey(identity: key, accountId: accountId));
        return AppAccountSignedIn(account: AppAccountRef(accountId: accountId, slot: slot), created: created);
      }
    }
    campusLog('[AppAccount] action=sign_in code=${RelayCode.badResponse} status=$status');
    throw const AppAccountException(AppAccountFailure.failed, '服务器的回复看不懂，请更新应用后再试');
  }

  @override
  void abandon(AccountIdentity identity) => _pending.remove(appAccountSlot(identity));

  @override
  Future<AppAccountSummary> summary(AccountIdentity identity) async {
    final slot = appAccountSlot(identity);
    final saved = await vault.read(slot);
    if (saved == null) throw const AppAccountException(AppAccountFailure.notSignedIn, '没有登录应用账号');
    try {
      final body = await _relayed(() => _relay.request(saved.identity, 'GET', '/v1/account'));
      final accountId = body['accountId'], providers = body['providers'], deviceCount = body['deviceCount'], createdAt = body['createdAt'];
      if (accountId is String && providers is List && providers.every((item) => item is String) && deviceCount is int && createdAt is int) {
        return AppAccountSummary(accountId: accountId, providers: providers.cast<String>(), deviceCount: deviceCount, createdAt: DateTime.fromMillisecondsSinceEpoch(createdAt, isUtc: true));
      }
      throw const AppAccountException(AppAccountFailure.failed, '服务器的回复看不懂，请更新应用后再试');
    } on AppAccountException catch (error) {
      // 账号在别处注销、被清理，或这把密钥被顶掉了：本机记录随之作废。
      if (error.failure == AppAccountFailure.notSignedIn) await vault.delete(slot);
      rethrow;
    }
  }

  @override
  Future<void> signOut(AccountIdentity identity) async {
    final slot = appAccountSlot(identity);
    _pending.remove(slot);
    final saved = await vault.read(slot);
    if (saved == null) return;
    try {
      await _relayed(() => _relay.deleteDevice(saved.identity));
    } on AppAccountException catch (error, stack) {
      // 服务端已不认、或这会儿连不上：照样删本机密钥（没了私钥谁也用不了那条登记，服务端按 400 天不活跃清掉）。
      campusLog('[AppAccount] action=sign_out failure=${error.failure.name} errorType=${error.runtimeType}\n$stack');
    }
    await vault.delete(slot);
  }

  @override
  Future<void> delete(AccountIdentity identity) async {
    final saved = await vault.read(appAccountSlot(identity));
    if (saved == null) throw const AppAccountException(AppAccountFailure.notSignedIn, '没有登录应用账号');
    try {
      await _relayed(() => _relay.request(saved.identity, 'DELETE', '/v1/account'));
    } on AppAccountException catch (error) {
      if (error.failure != AppAccountFailure.notSignedIn) rethrow;
    }
    await signOut(identity);
  }

  static bool _isBase64(String text) {
    try {
      return text.isNotEmpty && base64Decode(text).isNotEmpty;
    } on FormatException {
      return false;
    }
  }

  // 中转的错误码换成应用账号的失败（application 与 page 不认 social 的错误码）；断网与超时的原始异常与堆栈已由传输层记进日志。
  static Future<T> _relayed<T>(Future<T> Function() send) async {
    try {
      return await send();
    } on RelayException catch (error) {
      final detail = error.detail;
      final message = detail['message'];
      throw switch (error.code) {
        RelayCode.accountRejected => AppAccountException(AppAccountFailure.rejected, message is String && message.isNotEmpty && message.length <= 200 ? message : '教务没有通过这次登录'),
        RelayCode.captchaExpired => const AppAccountException(AppAccountFailure.captchaExpired, '验证码已过期，请重新登录'),
        RelayCode.upstreamUnavailable => AppAccountException(AppAccountFailure.upstream, switch (detail['reason']) {
          'rateLimited' => '教务提示请求太过频繁，请约 1 分钟后再试',
          'timeout' => '学校教务没有响应，请稍后再试',
          _ => '暂时连不上学校教务，请稍后再试',
        }),
        RelayCode.accountNotFound || RelayCode.unauthorized => const AppAccountException(AppAccountFailure.notSignedIn, '应用账号已经退出'),
        RelayCode.rateLimited => const AppAccountException(AppAccountFailure.rateLimited, '尝试太频繁，请稍后再试'),
        RelayCode.network || RelayCode.timeout => const AppAccountException(AppAccountFailure.network, '连不上服务器'),
        RelayCode.invalidRequest => const AppAccountException(AppAccountFailure.failed, '登录信息没能交给服务器，请更新应用后再试'),
        _ => AppAccountException(AppAccountFailure.failed, '服务器暂时不可用（${error.code}）'),
      };
    }
  }
}
