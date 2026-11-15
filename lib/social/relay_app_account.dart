import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:superxd/domain/account.dart';
import 'package:superxd/domain/app_account.dart';
import 'package:superxd/domain/campus_crypto.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/social/relay_client.dart';
import 'package:superxd/social/social_crypto.dart';

// 应用账号设备密钥的系统安全存储：单独的命名空间，与私信身份互不关联；同样排除出安卓云备份与设备迁移
// （backup_rules.xml、data_extraction_rules.xml），iOS 上仅本机级别、新装后第一次启动清掉（ios/Runner/DeviceOnlyData.swift）。
const appAccountStorage = FlutterSecureStorage(
  aOptions: AndroidOptions(storageNamespace: 'superxd_account', resetOnError: false),
  iOptions: IOSOptions(accountName: 'superxd_account', accessibility: KeychainAccessibility.first_unlock_this_device),
);

// 一个应用账号在本机的记录：设备密钥（同私信身份的格式）与账号号；accountId 为空是等待中（设备核对后学号已有账号，等扫码授权或找回生效），
// recoveryId 是这时提交的找回申请。
class AppAccountKey {
  const AppAccountKey({required this.identity, required this.accountId, this.recoveryId});
  final SocialIdentity identity;
  final String accountId;
  final String? recoveryId;

  bool get pending => accountId.isEmpty;
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
    if (data is! Map || data['version'] != 1 || data['sign'] is! String || data['box'] is! String || data['accountId'] is! String || (data['recovery'] != null && data['recovery'] is! String)) {
      throw const FormatException('保存的应用账号不可用');
    }
    return AppAccountKey(
      identity: await SocialIdentity.fromSeeds(decodeBase64UrlNoPad(data['sign'] as String, length: 32), decodeBase64UrlNoPad(data['box'] as String, length: 32)),
      accountId: data['accountId'] as String,
      recoveryId: data['recovery'] as String?,
    );
  }

  @override
  Future<void> write(String slot, AppAccountKey key) => _storage.write(
    key: slot,
    value: jsonEncode({'version': 1, 'sign': base64UrlNoPad(key.identity.signSeed), 'box': base64UrlNoPad(key.identity.boxSeed), 'accountId': key.accountId, 'recovery': ?key.recoveryId}),
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
final _recoveryIdPattern = RegExp(r'^\d{1,20}$');

// 应用账号端口的中转实现（人工决策见 domain/app_account.dart，协议见 server/README.md「应用账号」）：
// 签名请求、校时重发一次都复用私信的 RelayClient；每个教务账号一把单独的设备密钥。设备核对时学号已有账号，这把密钥先存成等待中，
// 扫码授权或找回生效后补上账号号（找回要等几天，重启应用也接着用这把）。
class RelayAppAccountClient implements AppAccountClient {
  RelayAppAccountClient({required this.vault, required RelayTransport transport}) : _relay = RelayClient(transport);
  final AppAccountVault vault;
  final RelayClient _relay;

  @override
  Future<AppAccountRef?> accountOf(AccountIdentity identity) async {
    final slot = appAccountSlot(identity);
    final saved = await vault.read(slot);
    return saved == null || saved.pending ? null : AppAccountRef(accountId: saved.accountId, slot: slot);
  }

  Map<String, Object?> _deviceBody(SocialIdentity key, AccountIdentity identity) => {
    'signPublicKey': base64UrlNoPad(key.signPublicKey),
    'boxPublicKey': base64UrlNoPad(key.boxPublicKey),
    'loginId': identity.loginId,
  };

  static String? _accountIdOf(Object? raw) => switch (raw) {
    {'accountId': final String accountId} when _accountIdPattern.hasMatch(accountId) => accountId,
    _ => null,
  };

  Future<AppAccountRef> _signedIn(String slot, SocialIdentity key, String accountId) async {
    await vault.write(slot, AppAccountKey(identity: key, accountId: accountId));
    return AppAccountRef(accountId: accountId, slot: slot);
  }

  // 等待中的密钥：设备核对过才有（服务端已登记这把设备密钥）。
  Future<AppAccountKey> _pendingKey(String slot) async {
    final saved = await vault.read(slot);
    if (saved == null || !saved.pending) throw const AppAccountException(AppAccountFailure.failed, '请重新登录应用账号');
    return saved;
  }

  static AppAccountFailure _bad(String action, Object? status) {
    campusLog('[AppAccount] action=$action code=${RelayCode.badResponse} status=$status');
    return AppAccountFailure.failed;
  }

  static const _badMessage = '服务器的回复看不懂，请更新应用后再试';

  @override
  Future<AppAccountStep> signInWithDevice(AccountIdentity identity) async {
    final slot = appAccountSlot(identity);
    final saved = await vault.read(slot);
    // 上次停在等待中的接着用那把密钥（找回申请记在它名下）；没有就新生成。
    final key = saved != null && saved.pending ? saved.identity : await SocialIdentity.generate();
    final body = await _relayed(() => _relay.request(key, 'POST', '/v1/account/device-sign-in', _deviceBody(key, identity)));
    final status = body['status'], accountId = _accountIdOf(body['account']);
    if (status == 'signedIn' && accountId != null) {
      return AppAccountSignedIn(account: await _signedIn(slot, key, accountId), created: (body['account']! as Map)['created'] == true);
    }
    if (status == 'exists') {
      if (saved == null || !saved.pending) await vault.write(slot, AppAccountKey(identity: key, accountId: ''));
      return const AppAccountExists();
    }
    throw AppAccountException(_bad('device_sign_in', status), _badMessage);
  }

  @override
  Future<AppAccountJoin> startJoin(AccountIdentity identity) async {
    final key = (await _pendingKey(appAccountSlot(identity))).identity;
    final body = await _relayed(() => _relay.request(key, 'POST', '/v1/account/joins', _deviceBody(key, identity)));
    final ticketId = body['ticketId'], code = body['code'], expiresAt = body['expiresAt'];
    if (ticketId is String && _accountIdPattern.hasMatch(ticketId) && code is String && RegExp(r'^\d{6}$').hasMatch(code) && expiresAt is int) {
      return AppAccountJoin(ticketId: ticketId, code: code, expiresAt: DateTime.fromMillisecondsSinceEpoch(expiresAt, isUtc: true));
    }
    throw AppAccountException(_bad('start_join', null), _badMessage);
  }

  @override
  Future<AppAccountRef?> joinState(AccountIdentity identity, AppAccountJoin join) async {
    final slot = appAccountSlot(identity);
    final key = (await _pendingKey(slot)).identity;
    final body = await _relayed(() => _relay.request(key, 'GET', '/v1/account/joins/${join.ticketId}'));
    final state = body['state'], accountId = _accountIdOf(body['account']);
    if (state == 'pending') return null;
    if (state == 'approved' && accountId != null) return _signedIn(slot, key, accountId);
    throw AppAccountException(_bad('join_state', state), _badMessage);
  }

  @override
  Future<void> approveJoin(AccountIdentity identity, String payload) async {
    final parsed = AppAccountJoin.parse(payload);
    if (parsed == null) throw const AppAccountException(AppAccountFailure.joinExpired, '不是应用账号的授权二维码');
    final saved = await vault.read(appAccountSlot(identity));
    if (saved == null || saved.pending) throw const AppAccountException(AppAccountFailure.notSignedIn, '没有登录应用账号');
    await _relayed(() => _relay.request(saved.identity, 'POST', '/v1/account/joins/${parsed.ticketId}/approve', {'code': parsed.code}));
  }

  AppAccountRecovery _recovery(Map<String, Object?> body) {
    final id = body['recoveryId'], state = body['state'], grantAt = body['grantAt'];
    final parsed = AppAccountRecoveryState.values.where((item) => item.name == state).firstOrNull;
    if (id is String && _recoveryIdPattern.hasMatch(id) && parsed != null && grantAt is int) {
      return AppAccountRecovery(id: id, state: parsed, grantAt: DateTime.fromMillisecondsSinceEpoch(grantAt, isUtc: true));
    }
    throw AppAccountException(_bad('recovery', state), _badMessage);
  }

  @override
  Future<AppAccountRecovery> requestRecovery(AccountIdentity identity) async {
    final slot = appAccountSlot(identity);
    final saved = await _pendingKey(slot);
    final recovery = _recovery(await _relayed(() => _relay.request(saved.identity, 'POST', '/v1/account/recoveries', _deviceBody(saved.identity, identity))));
    await vault.write(slot, AppAccountKey(identity: saved.identity, accountId: '', recoveryId: recovery.id));
    return recovery;
  }

  @override
  Future<AppAccountRecovery?> recoveryOf(AccountIdentity identity) async {
    final slot = appAccountSlot(identity);
    final saved = await vault.read(slot);
    if (saved == null || !saved.pending || saved.recoveryId == null) return null;
    final Map<String, Object?> body;
    try {
      body = await _relayed(() => _relay.request(saved.identity, 'GET', '/v1/account/recoveries/mine'));
    } on AppAccountException catch (error) {
      if (error.failure != AppAccountFailure.notSignedIn) rethrow;
      // 申请满 30 天被清理、或账号已注销：本机不再记着它。
      await vault.write(slot, AppAccountKey(identity: saved.identity, accountId: ''));
      return null;
    }
    final recovery = _recovery(body);
    if (recovery.state == AppAccountRecoveryState.granted) {
      final accountId = _accountIdOf(body['account']);
      if (accountId == null) throw AppAccountException(_bad('recovery_granted', null), _badMessage);
      await _signedIn(slot, saved.identity, accountId);
    }
    return recovery;
  }

  @override
  Future<void> decideRecovery(AccountIdentity identity, String recoveryId, {required bool approve}) async {
    final saved = await vault.read(appAccountSlot(identity));
    if (saved == null || saved.pending) throw const AppAccountException(AppAccountFailure.notSignedIn, '没有登录应用账号');
    await _relayed(() => _relay.request(saved.identity, 'POST', '/v1/account/recoveries/$recoveryId/${approve ? 'approve' : 'deny'}'));
  }

  @override
  Future<AppAccountSummary> summary(AccountIdentity identity) async {
    final slot = appAccountSlot(identity);
    final saved = await vault.read(slot);
    if (saved == null || saved.pending) throw const AppAccountException(AppAccountFailure.notSignedIn, '没有登录应用账号');
    try {
      final body = await _relayed(() => _relay.request(saved.identity, 'GET', '/v1/account'));
      final accountId = body['accountId'], providers = body['providers'], deviceCount = body['deviceCount'], createdAt = body['createdAt'], recoveries = body['recoveries'];
      if (accountId is String && providers is List && providers.every((item) => item is String) && deviceCount is int && createdAt is int && recoveries is List) {
        return AppAccountSummary(
          accountId: accountId,
          providers: providers.cast<String>(),
          deviceCount: deviceCount,
          createdAt: DateTime.fromMillisecondsSinceEpoch(createdAt, isUtc: true),
          recoveries: [
            for (final item in recoveries)
              if (item case {'recoveryId': final String id, 'createdAt': final int created, 'grantAt': final int grant} when _recoveryIdPattern.hasMatch(id))
                AppAccountPendingRecovery(id: id, createdAt: DateTime.fromMillisecondsSinceEpoch(created, isUtc: true), grantAt: DateTime.fromMillisecondsSinceEpoch(grant, isUtc: true)),
          ],
        );
      }
      throw const AppAccountException(AppAccountFailure.failed, _badMessage);
    } on AppAccountException catch (error) {
      // 账号在别处注销、被清理，或这把密钥被顶掉了：本机记录随之作废。
      if (error.failure == AppAccountFailure.notSignedIn) await vault.delete(slot);
      rethrow;
    }
  }

  @override
  Future<void> signOut(AccountIdentity identity) async {
    final slot = appAccountSlot(identity);
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
    if (saved == null || saved.pending) throw const AppAccountException(AppAccountFailure.notSignedIn, '没有登录应用账号');
    try {
      await _relayed(() => _relay.request(saved.identity, 'DELETE', '/v1/account'));
    } on AppAccountException catch (error) {
      if (error.failure != AppAccountFailure.notSignedIn) rethrow;
    }
    await signOut(identity);
  }

  // 中转的错误码换成应用账号的失败（application 与 page 不认 social 的错误码）；断网与超时的原始异常与堆栈已由传输层记进日志。
  static Future<T> _relayed<T>(Future<T> Function() send) async {
    try {
      return await send();
    } on RelayException catch (error) {
      throw switch (error.code) {
        RelayCode.joinNotFound => const AppAccountException(AppAccountFailure.joinExpired, '二维码或申请已过期，请重新开始'),
        RelayCode.joinMismatch => const AppAccountException(AppAccountFailure.joinMismatch, '这是别的学号的应用账号'),
        RelayCode.accountNotFound || RelayCode.unauthorized => const AppAccountException(AppAccountFailure.notSignedIn, '应用账号已经退出'),
        RelayCode.rateLimited => const AppAccountException(AppAccountFailure.rateLimited, '尝试太频繁，请稍后再试'),
        RelayCode.network || RelayCode.timeout => const AppAccountException(AppAccountFailure.network, '连不上服务器'),
        RelayCode.invalidRequest => const AppAccountException(AppAccountFailure.failed, '登录信息没能交给服务器，请更新应用后再试'),
        _ => AppAccountException(AppAccountFailure.failed, '服务器暂时不可用（${error.code}）'),
      };
    }
  }
}
