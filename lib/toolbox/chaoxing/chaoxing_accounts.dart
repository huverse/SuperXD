import 'package:superxd/toolbox/chaoxing/chaoxing_client.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_credential_pack.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_http.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_store.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_vault.dart';

// 学习通账号的闭环：登录、恢复会话、切换与删除。凭据在安全存储，账号索引在本机库。
class ChaoxingAccounts {
  ChaoxingAccounts({required this.store, required this.vault, ChaoxingHttp Function(ChaoxingCookieJar)? transport})
    : _transport = transport ?? ((cookies) => ChaoxingHttp(cookies: cookies));

  final ChaoxingStore store;
  final ChaoxingVault vault;
  final ChaoxingHttp Function(ChaoxingCookieJar) _transport;

  Future<List<ChaoxingAccountRecord>> list() => store.accounts();

  Future<ChaoxingAccountRecord?> record(String phoneNumber) async =>
      (await store.accounts()).where((item) => item.phoneNumber == phoneNumber).firstOrNull;

  // 本人账号在登录前就占位，他人的凭据包导入在后面的阶段接上。
  Future<ChaoxingAccount> signIn({
    required String phoneNumber,
    required String password,
    bool isOtherUser = false,
  }) async {
    if (!isOtherUser && (await store.accounts()).any((item) => item.isOtherUser && item.phoneNumber == phoneNumber)) {
      throw const ChaoxingFailure(ChaoxingFailureCode.invalidInput, '该账号已作为他人的账号存在');
    }
    final client = await ChaoxingClient.signIn(
      http: _transport(ChaoxingCookieJar()),
      phoneNumber: phoneNumber,
      password: password,
      deviceCode: chaoxingDeviceCode(),
    );
    await _persist(client, isOtherUser: isOtherUser);
    return client.account!;
  }

  Future<ChaoxingClient?> clientFor(String phoneNumber) async {
    final stored = await record(phoneNumber);
    if (stored == null) return null;
    final http = _transport(ChaoxingCookieJar(session: await vault.readCookies(phoneNumber)));
    return ChaoxingClient(
      http: http,
      phoneNumber: phoneNumber,
      encryptedPassword: await vault.readPassword(phoneNumber) ?? '',
      deviceCode: stored.deviceCode,
      account: ChaoxingAccount(
        phoneNumber: phoneNumber,
        uid: stored.uid,
        puid: stored.puid,
        fid: stored.fid,
        name: stored.name,
        deviceCode: stored.deviceCode,
        schoolName: stored.schoolName,
        clientId: stored.clientId.isEmpty ? null : stored.clientId,
      ),
    );
  }

  // 会话过期时自动重登一次并重放这次请求；再失败就交给用户重新登录。
  Future<T> run<T>(ChaoxingClient client, Future<T> Function() action) async {
    try {
      return await action();
    } on ChaoxingFailure catch (error, stack) {
      if (error.code != ChaoxingFailureCode.sessionExpired) rethrow;
      try {
        await client.reLogin();
      } on ChaoxingFailure {
        Error.throwWithStackTrace(error, stack);
      }
      await _persist(client, isOtherUser: (await record(client.phoneNumber))?.isOtherUser ?? false);
      return await action();
    }
  }

  // 导入别人的代签凭据：密文密码与对方设备码进安全存储，再登录一次拿真实的 uid/fid 与昵称。
  // 带上对方的设备码，用它签到时学习通不会提示「更换了签到设备」。
  Future<ChaoxingAccountRecord> importOther(ChaoxingCredentialPack pack) async {
    final existing = await record(pack.phoneNumber);
    if (existing != null && !existing.isOtherUser) {
      throw const ChaoxingFailure(ChaoxingFailureCode.invalidInput, '这是你自己的账号，不用导入代签码');
    }
    final client = ChaoxingClient(
      http: _transport(ChaoxingCookieJar()),
      phoneNumber: pack.phoneNumber,
      encryptedPassword: pack.encryptedPassword,
      deviceCode: pack.deviceCode,
    );
    try {
      await client.login();
      client.account = await client.loadAccount();
    } on ChaoxingFailure catch (error) {
      client.close();
      throw ChaoxingFailure(
        error.code == ChaoxingFailureCode.login ? ChaoxingFailureCode.login : error.code,
        '这个账号登不上去，请让对方重新生成代签码',
      );
    }
    await _persist(client, isOtherUser: true, name: pack.name, createdAt: existing?.createdAt);
    return (await record(pack.phoneNumber))!;
  }

  Future<void> forget(String phoneNumber) async {
    await store.removeAccount(phoneNumber);
    await vault.delete(phoneNumber);
  }

  Future<void> _persist(
    ChaoxingClient client, {
    required bool isOtherUser,
    String? name,
    DateTime? createdAt,
  }) async {
    final account = client.account!;
    await vault.writePassword(client.phoneNumber, client.encryptedPassword);
    await vault.writeCookies(client.phoneNumber, client.http.cookies.session);
    await store.putAccount(
      ChaoxingAccountRecord(
        phoneNumber: client.phoneNumber,
        uid: account.uid,
        puid: account.puid,
        fid: account.fid,
        name: name?.isNotEmpty == true ? name! : account.name,
        schoolName: account.schoolName,
        deviceCode: client.deviceCode,
        isOtherUser: isOtherUser,
        createdAt: createdAt ?? DateTime.now().toUtc(),
        clientId: account.clientId ?? '',
      ),
    );
  }

  // 人脸识别签到要 clientId 做设备签名；旧的库里没有时补写回去，省得每次重新取。
  Future<void> rememberClientId(String phoneNumber, String clientId) async {
    if (clientId.isEmpty) return;
    final existing = await record(phoneNumber);
    if (existing == null || existing.clientId == clientId) return;
    await store.putAccount(
      ChaoxingAccountRecord(
        phoneNumber: existing.phoneNumber,
        uid: existing.uid,
        puid: existing.puid,
        fid: existing.fid,
        name: existing.name,
        schoolName: existing.schoolName,
        deviceCode: existing.deviceCode,
        isOtherUser: existing.isOtherUser,
        createdAt: existing.createdAt,
        clientId: clientId,
      ),
    );
  }
}
