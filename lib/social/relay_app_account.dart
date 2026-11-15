import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:superxd/domain/app_account.dart';
import 'package:superxd/domain/campus_crypto.dart';
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

// 一个应用账号在本机的记录：设备密钥（同私信身份的格式）、账号号与用户名（11-15 以前的旧记录没有用户名，为空）。
class AppAccountKey {
  const AppAccountKey({required this.identity, required this.accountId, this.username = ''});
  final SocialIdentity identity;
  final String accountId;
  final String username;
}

abstract interface class AppAccountVault {
  Future<AppAccountKey?> read(String slot);
  Future<void> write(String slot, AppAccountKey key);
  Future<void> delete(String slot);
  // 存着的全部键（清理 11-15 以前每个教务账号一把的旧密钥时用）。
  Future<List<String>> slots();
}

class SecureAppAccountVault implements AppAccountVault {
  const SecureAppAccountVault([this._storage = appAccountStorage]);
  final FlutterSecureStorage _storage;

  @override
  Future<AppAccountKey?> read(String slot) async {
    final raw = await _storage.read(key: slot);
    if (raw == null) return null;
    final data = jsonDecode(raw);
    if (data is! Map || data['version'] != 1 || data['sign'] is! String || data['box'] is! String || data['accountId'] is! String || (data['username'] ?? '') is! String) {
      throw const FormatException('保存的应用账号不可用');
    }
    return AppAccountKey(
      identity: await SocialIdentity.fromSeeds(decodeBase64UrlNoPad(data['sign'] as String, length: 32), decodeBase64UrlNoPad(data['box'] as String, length: 32)),
      accountId: data['accountId'] as String,
      username: (data['username'] ?? '') as String,
    );
  }

  @override
  Future<void> write(String slot, AppAccountKey key) => _storage.write(
    key: slot,
    value: jsonEncode({'version': 1, 'sign': base64UrlNoPad(key.identity.signSeed), 'box': base64UrlNoPad(key.identity.boxSeed), 'accountId': key.accountId, 'username': key.username}),
  );

  @override
  Future<void> delete(String slot) => _storage.delete(key: slot);

  @override
  Future<List<String>> slots() async => (await _storage.readAll()).keys.toList();
}

class MemoryAppAccountVault implements AppAccountVault {
  final records = <String, AppAccountKey>{};
  @override
  Future<AppAccountKey?> read(String slot) async => records[slot];
  @override
  Future<void> write(String slot, AppAccountKey key) async => records[slot] = key;
  @override
  Future<void> delete(String slot) async => records.remove(slot);
  @override
  Future<List<String>> slots() async => records.keys.toList();
}

// 安全存储里这台设备应用账号的键（11-15 起一台设备一个，与教务各管各的）。11-15 以前每个教务账号一把，键是 account.<教务身份的哈希>。
const appAccountSlot = 'app_account';
const _legacySlotPrefix = 'account.';

final _accountIdPattern = RegExp(r'^[A-Za-z0-9_-]{22}$');

// 应用账号端口的中转实现（人工决策见 domain/app_account.dart，协议见 server/README.md「应用账号」）：
// 签名请求、校时重发一次都复用私信的 RelayClient；这台设备一把设备密钥，登录成功才连同账号号存进安全存储。
// 注册、登录、用恢复码重设都先生成一把新密钥（服务端把它登记到账号下），密码与恢复码经 account_seal.dart 封装后才发出。
class RelayAppAccountClient implements AppAccountClient {
  RelayAppAccountClient({required this.vault, required RelayTransport transport, List<int>? sealKey, this.deviceModel})
    : _relay = RelayClient(transport),
      _sealKey = sealKey ?? decodeBase64UrlNoPad(accountSealKey, length: 32);
  final AppAccountVault vault;
  final RelayClient _relay;
  final List<int> _sealKey;
  // 这台手机的机型（安卓厂商加型号、iOS 机型名，组合根从 device 层注入；测试不给），扫码登录出示时带上给批准方核对。
  final Future<String?> Function()? deviceModel;

  @override
  Future<AppAccountSession?> accountOf() async {
    final saved = await vault.read(appAccountSlot);
    return saved == null ? null : AppAccountSession(account: AppAccountRef(accountId: saved.accountId, slot: appAccountSlot), username: saved.username);
  }

  Future<AppAccountSession> _save(SocialIdentity key, String accountId, String username) async {
    await vault.write(appAccountSlot, AppAccountKey(identity: key, accountId: accountId, username: username));
    return AppAccountSession(account: AppAccountRef(accountId: accountId, slot: appAccountSlot), username: username);
  }

  static final _usernamePattern = RegExp(r'^[a-z0-9_]{3,20}$');

  @override
  Future<List<AppAccountRef>> dropLegacy() async {
    final dropped = <AppAccountRef>[];
    for (final slot in (await vault.slots()).where((slot) => slot.startsWith(_legacySlotPrefix))) {
      try {
        final saved = await vault.read(slot);
        if (saved != null) dropped.add(AppAccountRef(accountId: saved.accountId, slot: slot));
      } on FormatException catch (error, stack) {
        campusLog('[AppAccount] action=drop_legacy errorType=${error.runtimeType}\n$stack');
      }
      await vault.delete(slot);
    }
    return dropped;
  }

  Map<String, Object?> _keys(SocialIdentity key) => {'signPublicKey': base64UrlNoPad(key.signPublicKey), 'boxPublicKey': base64UrlNoPad(key.boxPublicKey)};

  Future<String> _seal(SocialIdentity key, Map<String, Object?> secrets) async => base64UrlNoPad(await sealAccountSecrets(secrets, key.deviceId, _sealKey));

  static const _badMessage = '服务器的回复看不懂，请更新应用后再试';

  static AppAccountException _bad(String action) {
    campusLog('[AppAccount] action=$action code=${RelayCode.badResponse}');
    return const AppAccountException(AppAccountFailure.failed, _badMessage);
  }

  // 注册、登录、重设共用：新生成一把设备密钥，带着封装好的秘密发出，成功才存本机。
  Future<AppAccountSession> _credential(String action, String path, String username, Map<String, Object?> secrets) async {
    final key = await SocialIdentity.generate();
    final body = await _relayed(() async => _relay.request(key, 'POST', path, {..._keys(key), 'username': normalizeAppUsername(username), 'sealed': await _seal(key, secrets)}));
    final accountId = body['accountId'], name = body['username'];
    if (accountId is! String || !_accountIdPattern.hasMatch(accountId) || name is! String || !_usernamePattern.hasMatch(name)) throw _bad(action);
    return _save(key, accountId, name);
  }

  @override
  Future<AppAccountSession> register(String username, String password, String recoveryCode) =>
      _credential('register', '/v1/account/register', username, {'password': password, 'recoveryCode': recoveryCode});

  @override
  Future<AppAccountSession> login(String username, String password) => _credential('login', '/v1/account/login', username, {'password': password});

  @override
  Future<AppAccountSession> recover(String username, String recoveryCode, String password, String newRecoveryCode) =>
      _credential('recover', '/v1/account/recover', username, {'recoveryCode': recoveryCode, 'password': password, 'newRecoveryCode': newRecoveryCode});

  Future<AppAccountKey> _signedIn() async {
    final saved = await vault.read(appAccountSlot);
    if (saved == null) throw const AppAccountException(AppAccountFailure.notSignedIn, '没有登录应用账号');
    return saved;
  }

  @override
  Future<void> changePassword(String password) async {
    final saved = await _signedIn();
    await _relayed(() async => _relay.request(saved.identity, 'POST', '/v1/account/password', {'sealed': await _seal(saved.identity, {'password': password})}));
  }

  @override
  Future<void> changeRecoveryCode(String recoveryCode) async {
    final saved = await _signedIn();
    await _relayed(() async => _relay.request(saved.identity, 'POST', '/v1/account/recovery-code', {'sealed': await _seal(saved.identity, {'recoveryCode': recoveryCode})}));
  }

  // 扫码登录出示二维码用的密钥：出示时新生成、只放内存，批准了才存进安全存储（没批准就丢，服务端那条登记按 400 天不活跃清掉）。
  SocialIdentity? _joinKey;

  // 机型是给批准方看的一行字：去掉首尾空白与控制字符，最多 64 个字符（同服务端 accountJoinDeviceMaxLength），读不出就不带。
  Future<String?> _model() async {
    final read = deviceModel;
    if (read == null) return null;
    try {
      final model = (await read())?.replaceAll(RegExp(r'\p{C}', unicode: true), '').trim();
      return model == null || model.isEmpty ? null : String.fromCharCodes(model.runes.take(64));
    } catch (error, stack) {
      campusLog('[AppAccount] action=device_model errorType=${error.runtimeType}\n$stack');
      return null;
    }
  }

  @override
  Future<AppAccountJoin> startJoin() async {
    final key = _joinKey = await SocialIdentity.generate();
    final model = await _model();
    final body = await _relayed(() => _relay.request(key, 'POST', '/v1/account/joins', {..._keys(key), 'device': ?model}));
    final ticketId = body['ticketId'], code = body['code'], expiresAt = body['expiresAt'];
    if (ticketId is String && _accountIdPattern.hasMatch(ticketId) && code is String && RegExp(r'^\d{6}$').hasMatch(code) && expiresAt is int) {
      // 失效时刻是服务器时钟，换成本机时钟给出示页倒数（手机时钟不准、校时过时，不换就一出示就显示已失效、不再问批准）。
      return AppAccountJoin(ticketId: ticketId, code: code, expiresAt: DateTime.fromMillisecondsSinceEpoch(expiresAt - _relay.clockOffset, isUtc: true));
    }
    throw _bad('start_join');
  }

  @override
  Future<AppAccountSession?> joinState(AppAccountJoin join) async {
    final key = _joinKey;
    if (key == null) throw const AppAccountException(AppAccountFailure.joinExpired, '二维码已过期，请刷新');
    final body = await _relayed(() => _relay.request(key, 'GET', '/v1/account/joins/${join.ticketId}'));
    final state = body['state'], account = body['account'];
    if (state == 'pending') return null;
    if (state == 'approved') {
      if (account case {'accountId': final String accountId, 'username': final String name} when _accountIdPattern.hasMatch(accountId) && _usernamePattern.hasMatch(name)) {
        _joinKey = null;
        return _save(key, accountId, name);
      }
    }
    throw _bad('join_state');
  }

  // 离开出示页：用出示时那把临时密钥请中转作废这张票据（中转只作废还没批准的）；批准过（密钥已存）或没出示过不发。
  @override
  Future<void> cancelJoin(AppAccountJoin join) async {
    final key = _joinKey;
    if (key == null) return;
    await _relayed(() => _relay.request(key, 'DELETE', '/v1/account/joins/${join.ticketId}'));
  }

  // 批准前先看请求方：机型与属地都是外部输入，逐项校验（机型最多 64 个字符、属地最多 32 个），没有的为空。
  @override
  Future<AppAccountJoinRequest> inspectJoin(String payload) async {
    final parsed = AppAccountJoin.parse(payload);
    if (parsed == null) throw const AppAccountException(AppAccountFailure.joinExpired, '不是应用账号的登录二维码');
    final saved = await _signedIn();
    final body = await _relayed(() => _relay.request(saved.identity, 'POST', '/v1/account/joins/${parsed.ticketId}/inspect', {'code': parsed.code}));
    String? text(Object? value, int limit) => switch (value) {
      null => null,
      final String text when text.isNotEmpty && text.runes.length <= limit => text,
      _ => throw _bad('inspect_join'),
    };
    return AppAccountJoinRequest(device: text(body['device'], 64), region: text(body['region'], 32));
  }

  @override
  Future<void> approveJoin(String payload) async {
    final parsed = AppAccountJoin.parse(payload);
    if (parsed == null) throw const AppAccountException(AppAccountFailure.joinExpired, '不是应用账号的登录二维码');
    final saved = await _signedIn();
    await _relayed(() => _relay.request(saved.identity, 'POST', '/v1/account/joins/${parsed.ticketId}/approve', {'code': parsed.code}));
  }

  @override
  Future<AppAccountSummary> summary() async {
    final saved = await _signedIn();
    try {
      final body = await _relayed(() => _relay.request(saved.identity, 'GET', '/v1/account'));
      final accountId = body['accountId'], username = body['username'], deviceCount = body['deviceCount'], createdAt = body['createdAt'];
      if (accountId is String && username is String && deviceCount is int && createdAt is int) {
        return AppAccountSummary(accountId: accountId, username: username, deviceCount: deviceCount, createdAt: DateTime.fromMillisecondsSinceEpoch(createdAt, isUtc: true));
      }
      throw _bad('summary');
    } on AppAccountException catch (error) {
      // 账号在别处注销、被清理，或这把密钥被顶掉了：本机记录随之作废。
      if (error.failure == AppAccountFailure.notSignedIn || error.failure == AppAccountFailure.deleted) await vault.delete(appAccountSlot);
      rethrow;
    }
  }

  @override
  Future<void> signOut() async {
    final saved = await vault.read(appAccountSlot);
    if (saved == null) return;
    try {
      await _relayed(() => _relay.deleteDevice(saved.identity));
    } on AppAccountException catch (error, stack) {
      // 服务端已不认、或这会儿连不上：照样删本机密钥（没了私钥谁也用不了那条登记，服务端按 400 天不活跃清掉）。
      campusLog('[AppAccount] action=sign_out failure=${error.failure.name} errorType=${error.runtimeType}\n$stack');
    }
    await vault.delete(appAccountSlot);
  }

  @override
  Future<void> delete() async {
    final saved = await _signedIn();
    try {
      await _relayed(() => _relay.request(saved.identity, 'DELETE', '/v1/account'));
    } on AppAccountException catch (error) {
      if (error.failure != AppAccountFailure.notSignedIn) rethrow;
    }
    await signOut();
  }

  // 中转的错误码换成应用账号的失败（application 与 page 不认 social 的错误码）；断网与超时的原始异常与堆栈已由传输层记进日志。
  static Future<T> _relayed<T>(Future<T> Function() send) async {
    try {
      return await send();
    } on RelayException catch (error) {
      throw switch (error.code) {
        RelayCode.usernameTaken => const AppAccountException(AppAccountFailure.usernameTaken, '用户名已被占用'),
        RelayCode.credentialsInvalid => const AppAccountException(AppAccountFailure.credentialsInvalid, '用户名或密码不对'),
        RelayCode.joinNotFound => const AppAccountException(AppAccountFailure.joinExpired, '二维码已过期或不对，请刷新'),
        RelayCode.accountNotFound || RelayCode.unauthorized => const AppAccountException(AppAccountFailure.notSignedIn, '应用账号已经退出'),
        RelayCode.accountDeleted => const AppAccountException(AppAccountFailure.deleted, '应用账号已注销'),
        RelayCode.rateLimited => const AppAccountException(AppAccountFailure.rateLimited, '尝试太频繁，请稍后再试'),
        RelayCode.network || RelayCode.timeout => const AppAccountException(AppAccountFailure.network, '连不上服务器'),
        RelayCode.invalidRequest => const AppAccountException(AppAccountFailure.failed, '信息没能交给服务器，请更新应用后再试'),
        _ => AppAccountException(AppAccountFailure.failed, '服务器暂时不可用（${error.code}）'),
      };
    }
  }
}
