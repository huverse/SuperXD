import 'dart:async';

import 'package:synchronized/synchronized.dart';

import 'package:superxd/domain/app_account.dart';
import 'package:superxd/domain/campus_crypto.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/relay/account_relay.dart';
import 'package:superxd/relay/account_seal.dart';
import 'package:superxd/relay/app_account_vault.dart';
import 'package:superxd/relay/relay_client.dart';
import 'package:superxd/relay/relay_crypto.dart';

// 11-15 以前每个教务账号一把设备密钥，键是 account.<教务身份的哈希>（dropLegacy 清掉）。
const _legacySlotPrefix = 'account.';

final _accountIdPattern = RegExp(r'^[A-Za-z0-9_-]{22}$');

// 应用账号端口的中转实现（人工决策见 domain/app_account.dart，协议见 server/README.md「应用账号」）：
// 签名请求、校时重发一次与错误码的换法都走 AccountRelay（用给定的密钥签名）；这台设备一把设备密钥，登录成功才连同账号号存进安全存储。
// 注册、登录、用恢复码重设都先生成一把新密钥（服务端把它登记到账号下），密码与恢复码经 account_seal.dart 封装后才发出。
// 「账号已注销」要带服务器签名才认（RelayClient 核，验不过当连不上）；serverKeys 是受信的服务器在线签名公钥，测试换成测试钥。
class RelayAppAccountClient implements AppAccountClient {
  RelayAppAccountClient({required this.vault, required RelayTransport transport, List<int>? sealKey, this.deviceModel, List<String> serverKeys = relayServerKeys})
    : _relay = AccountRelay(vault: vault, transport: transport, serverKeys: serverKeys),
      _sealKey = sealKey ?? decodeBase64UrlNoPad(accountSealKey, length: 32);
  final AppAccountVault vault;
  final AccountRelay _relay;
  final List<int> _sealKey;
  // 这台手机的机型（安卓厂商加型号、iOS 机型名，组合根从 device 层注入；测试不给），扫码登录出示时带上给批准方核对。
  final Future<String?> Function()? deviceModel;

  @override
  Future<AppAccountSession?> accountOf() async {
    final saved = await vault.read(appAccountSlot);
    return saved == null ? null : AppAccountSession(account: AppAccountRef(accountId: saved.accountId, slot: appAccountSlot), username: saved.username);
  }

  // 本机这把密钥的写入与删除排成一个队（11-28 审查 F03）：删之前核对槽里还是读出来的那把，旧账号迟到的「账号不在了」不会删掉刚登录的新账号。
  final _vaultLock = Lock();

  Future<AppAccountSession> _save(RelayIdentity key, String accountId, String username) async {
    await _vaultLock.synchronized(() => vault.write(appAccountSlot, AppAccountKey(identity: key, accountId: accountId, username: username)));
    return AppAccountSession(account: AppAccountRef(accountId: accountId, slot: appAccountSlot), username: username);
  }

  // 删掉本机这把密钥，只在槽里还是 saved 那把（同一设备号）时删；已经换成别的账号或别的密钥就不动。
  Future<void> _forget(AppAccountKey saved) => _vaultLock.synchronized(() async {
    final current = await vault.read(appAccountSlot);
    if (current != null && current.identity.deviceId == saved.identity.deviceId) await vault.delete(appAccountSlot);
  });

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

  Map<String, Object?> _keys(RelayIdentity key) => {'signPublicKey': base64UrlNoPad(key.signPublicKey), 'boxPublicKey': base64UrlNoPad(key.boxPublicKey)};

  Future<String> _seal(RelayIdentity key, Map<String, Object?> secrets) async => base64UrlNoPad(await sealAccountSecrets(secrets, key.deviceId, _sealKey));

  static const _badMessage = '服务器的回复看不懂，请更新应用后再试';

  static AppAccountException _bad(String action) {
    campusLog('[AppAccount] action=$action code=${RelayCode.badResponse}');
    return const AppAccountException(AppAccountFailure.failed, _badMessage);
  }

  // 注册、登录、重设共用：新生成一把设备密钥，带着封装好的秘密发出，成功才存本机。改用这几种方式登录时，还在出示的扫码登录一律作废（审查 F04）。
  Future<AppAccountSession> _credential(String action, String path, String username, Map<String, Object?> secrets) async {
    _joins.clear();
    _joinEpoch++;
    final key = await RelayIdentity.generate();
    final body = await _relay.signedWith(key, 'POST', path, payload: {..._keys(key), 'username': normalizeAppUsername(username), 'sealed': await _seal(key, secrets)}, errors: _errors);
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
    await _relay.signedWith(saved.identity, 'POST', '/v1/account/password', payload: {'sealed': await _seal(saved.identity, {'password': password})}, errors: _errors);
  }

  @override
  Future<void> changeRecoveryCode(String recoveryCode) async {
    final saved = await _signedIn();
    await _relay.signedWith(saved.identity, 'POST', '/v1/account/recovery-code', payload: {'sealed': await _seal(saved.identity, {'recoveryCode': recoveryCode})}, errors: _errors);
  }

  // 扫码登录出示二维码用的密钥：出示时新生成、只放内存，按票据号各记一把，批准了才存进安全存储（没批准就丢，服务端那条登记按 400 天不活跃清掉）。
  // 11-28 审查 F04：离开出示页、刷新或改用别的方式登录时立即从这里拿掉，已经发出的轮询晚回来说批准了也不存、不登录（不覆盖之后的登录）。
  // 一个出示页同时只有一两张，最多记 _joinLimit 张。
  final _joins = <String, RelayIdentity>{};
  static const _joinLimit = 4;
  // 改用别的方式登录的次数：出示请求在路上时登录了别的，回来的那张不再记。
  var _joinEpoch = 0;

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
    final epoch = _joinEpoch;
    final key = await RelayIdentity.generate();
    final model = await _model();
    final body = await _relay.signedWith(key, 'POST', '/v1/account/joins', payload: {..._keys(key), 'device': ?model}, errors: _errors);
    final ticketId = body['ticketId'], code = body['code'], expiresAt = body['expiresAt'];
    if (ticketId is String && _accountIdPattern.hasMatch(ticketId) && code is String && RegExp(r'^\d{6}$').hasMatch(code) && expiresAt is int) {
      if (epoch != _joinEpoch) throw const AppAccountException(AppAccountFailure.joinExpired, '已经用别的方式登录了');
      if (_joins.length >= _joinLimit) _joins.remove(_joins.keys.first);
      _joins[ticketId] = key;
      // 失效时刻是服务器时钟，换成本机时钟给出示页倒数（手机时钟不准、校时过时，不换就一出示就显示已失效、不再问批准）。
      return AppAccountJoin(ticketId: ticketId, code: code, expiresAt: DateTime.fromMillisecondsSinceEpoch(expiresAt - _relay.clockOffset, isUtc: true));
    }
    throw _bad('start_join');
  }

  static const _joinGone = AppAccountException(AppAccountFailure.joinExpired, '二维码已过期，请刷新');

  @override
  Future<AppAccountSession?> joinState(AppAccountJoin join) async {
    final key = _joins[join.ticketId];
    if (key == null) throw _joinGone;
    final body = await _relay.signedWith(key, 'GET', '/v1/account/joins/${join.ticketId}', errors: _errors);
    final state = body['state'], account = body['account'];
    if (state == 'pending') return null;
    if (state == 'approved') {
      if (account case {'accountId': final String accountId, 'username': final String name} when _accountIdPattern.hasMatch(accountId) && _usernamePattern.hasMatch(name)) {
        bool current() => identical(_joins[join.ticketId], key);
        // 这一问在路上时离开了出示页、刷新了或登录了别的：不存这把密钥、不登录。
        if (!current()) throw _dropStale(key);
        // 11-28 复核 F04：核对、写入与写后复核在同一个队里做完，票据写完才拿掉。排队等着写、或正在写安全存储时离开了出示页（cancelJoin）
        // 或改用别的方式登录（_credential），写之前就不写；已经写了的放回写之前的那条（锁还在手里，没别人动过槽），都不登录。
        return _vaultLock.synchronized(() async {
          if (!current()) throw _dropStale(key);
          // 原来那条认不出（坏了）就当没有，同以前直接覆盖。
          final previous = await vault.read(appAccountSlot).then<AppAccountKey?>((saved) => saved, onError: (Object error) => error is FormatException || error is RelayCryptoException ? null : throw error);
          await vault.write(appAccountSlot, AppAccountKey(identity: key, accountId: accountId, username: name));
          if (!current()) {
            await (previous == null ? vault.delete(appAccountSlot) : vault.write(appAccountSlot, previous));
            throw _dropStale(key);
          }
          _joins.remove(join.ticketId);
          return AppAccountSession(account: AppAccountRef(accountId: accountId, slot: appAccountSlot), username: name);
        });
      }
    }
    throw _bad('join_state');
  }

  // 作废了的扫码登录晚到的批准：顺手请中转删掉批准时登记的这台设备（不等，失败只记日志），交出「二维码已过期」。
  AppAccountException _dropStale(RelayIdentity key) {
    campusLog('[AppAccount] action=join_state result=stale');
    unawaited(_relay.signedWith(key, 'DELETE', '/v1/devices', errors: _errors).then<void>((_) {}, onError: (Object error, StackTrace stack) => campusLog('[AppAccount] action=drop_stale_join errorType=${error.runtimeType}\n$stack')));
    return _joinGone;
  }

  // 离开出示页或刷新：先在本机作废（之后回来的批准不再认），再用那把临时密钥请中转作废这张票据（中转只作废还没批准的）；批准过（密钥已存）或没出示过不发。
  @override
  Future<void> cancelJoin(AppAccountJoin join) async {
    final key = _joins.remove(join.ticketId);
    if (key == null) return;
    await _relay.signedWith(key, 'DELETE', '/v1/account/joins/${join.ticketId}', errors: _errors);
  }

  // 批准前先看请求方：机型与属地都是外部输入，逐项校验（机型最多 64 个字符、属地最多 32 个），没有的为空。
  @override
  Future<AppAccountJoinRequest> inspectJoin(String payload) async {
    final parsed = AppAccountJoin.parse(payload);
    if (parsed == null) throw const AppAccountException(AppAccountFailure.joinExpired, '不是应用账号的登录二维码');
    final saved = await _signedIn();
    final body = await _relay.signedWith(saved.identity, 'POST', '/v1/account/joins/${parsed.ticketId}/inspect', payload: {'code': parsed.code}, errors: _errors);
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
    await _relay.signedWith(saved.identity, 'POST', '/v1/account/joins/${parsed.ticketId}/approve', payload: {'code': parsed.code}, errors: _errors);
  }

  @override
  Future<AppAccountSummary> summary() async {
    final saved = await _signedIn();
    try {
      final body = await _relay.signedWith(saved.identity, 'GET', '/v1/account', errors: _errors);
      final accountId = body['accountId'], username = body['username'], deviceCount = body['deviceCount'], createdAt = body['createdAt'];
      if (accountId is String && username is String && deviceCount is int && createdAt is int) {
        return AppAccountSummary(accountId: accountId, username: username, deviceCount: deviceCount, createdAt: DateTime.fromMillisecondsSinceEpoch(createdAt, isUtc: true));
      }
      throw _bad('summary');
    } on AppAccountException catch (error) {
      // 账号在别处注销、被清理，或这把密钥被顶掉了：本机记录随之作废（只删发这次请求的那把，这一问在路上时换成的别的账号不动）。
      if (error.failure == AppAccountFailure.notSignedIn || error.failure == AppAccountFailure.deleted) await _forget(saved);
      rethrow;
    }
  }

  @override
  Future<void> signOut() async {
    final saved = await vault.read(appAccountSlot);
    if (saved == null) return;
    try {
      await _relay.signedWith(saved.identity, 'DELETE', '/v1/devices', errors: _errors);
    } on AppAccountException catch (error, stack) {
      // 服务端已不认、或这会儿连不上：照样删本机密钥（没了私钥谁也用不了那条登记，服务端按 400 天不活跃清掉）。
      campusLog('[AppAccount] action=sign_out failure=${error.failure.name} errorType=${error.runtimeType}\n$stack');
    }
    await _forget(saved);
  }

  @override
  Future<void> delete() async {
    final saved = await _signedIn();
    try {
      await _relay.signedWith(saved.identity, 'DELETE', '/v1/account', errors: _errors);
    } on AppAccountException catch (error) {
      if (error.failure != AppAccountFailure.notSignedIn) rethrow;
    }
    await signOut();
  }

  // 中转的错误码换成应用账号的失败（application 与 page 不认中转的错误码）；断网与超时的原始异常与堆栈已由传输层记进日志。
  static final _errors = RelayErrors(
    signedOut: const AppAccountException(AppAccountFailure.notSignedIn, '应用账号已经退出'),
    network: const AppAccountException(AppAccountFailure.network, '连不上服务器'),
    rateLimited: const AppAccountException(AppAccountFailure.rateLimited, '尝试太频繁，请稍后再试'),
    failed: (code) => AppAccountException(AppAccountFailure.failed, '服务器暂时不可用（$code）'),
    codes: {
      RelayCode.usernameTaken: (_) => const AppAccountException(AppAccountFailure.usernameTaken, '用户名已被占用'),
      RelayCode.credentialsInvalid: (_) => const AppAccountException(AppAccountFailure.credentialsInvalid, '用户名或密码不对'),
      RelayCode.joinNotFound: (_) => const AppAccountException(AppAccountFailure.joinExpired, '二维码已过期或不对，请刷新'),
      RelayCode.accountDeleted: (_) => const AppAccountException(AppAccountFailure.deleted, '应用账号已注销'),
      RelayCode.invalidRequest: (_) => const AppAccountException(AppAccountFailure.failed, '信息没能交给服务器，请更新应用后再试'),
    },
  );
}
