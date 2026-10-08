import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_client.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_credential_pack.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_crypto.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_device.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_http.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_store.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_vault.dart';

// 设置里存模拟客户端的键：preset id，或 custom 加自定义 UA 与包名。
const chaoxingProfileKey = 'client_profile';
const chaoxingCustomUserAgentKey = 'client_user_agent';
const chaoxingCustomPackageKey = 'client_package';

// 学习通账号的闭环：登录、恢复会话、切换学校单位、修复与删除。凭据在安全存储，账号索引在本机库。
class ChaoxingAccounts {
  ChaoxingAccounts({
    required this.store,
    required this.vault,
    ChaoxingHttp Function(ChaoxingCookieJar)? transport,
    this.device,
  }) : _transport = transport ?? ((cookies) => ChaoxingHttp(cookies: cookies));

  final ChaoxingStore store;
  final ChaoxingVault vault;
  final ChaoxingHttp Function(ChaoxingCookieJar) _transport;

  // 设备信息与 OAID 的来源；测试里为空（用户信息照旧 GET、设备码用固定随机）。
  final ChaoxingDeviceProbe? device;

  ChaoxingClientProfile profile = ChaoxingClientProfile.chaoxing;

  Future<List<ChaoxingAccountRecord>> list() => store.accounts();

  Future<ChaoxingAccountRecord?> record(String phoneNumber) async =>
      (await store.accounts()).where((item) => item.phoneNumber == phoneNumber).firstOrNull;

  static const full = ChaoxingFailure(ChaoxingFailureCode.invalidInput, '最多保存 ${ChaoxingStore.accountLimit} 个学习通账号，请先删掉不用的');

  // 新账号写入前检查上限：读取只取前 21 个，超出的会在列表里消失、凭据也删不掉，所以在写入前拦下。
  Future<void> ensureRoomFor(String phoneNumber) async {
    final existing = await store.accounts();
    if (existing.any((item) => item.phoneNumber == phoneNumber.trim())) return;
    if (existing.length >= ChaoxingStore.accountLimit) throw full;
  }

  // 打开页面时读一次设置里的模拟客户端。
  Future<void> loadProfile() async {
    final id = await store.preference(chaoxingProfileKey);
    if (id == ChaoxingClientProfile.customId) {
      final userAgent = await store.preference(chaoxingCustomUserAgentKey) ?? '';
      profile = ChaoxingClientProfile.userAgentProblem(userAgent) == null
          ? ChaoxingClientProfile.custom(userAgent: userAgent, packageName: await store.preference(chaoxingCustomPackageKey) ?? '')
          : ChaoxingClientProfile.chaoxing;
      return;
    }
    profile = ChaoxingClientProfile.presets.where((item) => item.id == id).firstOrNull ?? ChaoxingClientProfile.chaoxing;
  }

  Future<void> saveProfile(ChaoxingClientProfile value) async {
    await store.setPreference(chaoxingProfileKey, value.id);
    await store.setPreference(chaoxingCustomUserAgentKey, value.id == ChaoxingClientProfile.customId ? value.userAgent : null);
    await store.setPreference(chaoxingCustomPackageKey, value.id == ChaoxingClientProfile.customId ? value.packageName : null);
    profile = value;
  }

  ChaoxingHttp _http(ChaoxingCookieJar cookies) => _transport(cookies)..profile = profile;

  // 本人账号：本机能取到 OAID 就用与学习通客户端一致的设备码，取不到用固定随机码。
  Future<ChaoxingAccount> signIn({
    required String phoneNumber,
    required String password,
  }) async {
    if ((await store.accounts()).any((item) => item.isOtherUser && item.phoneNumber == phoneNumber.trim())) {
      throw const ChaoxingFailure(ChaoxingFailureCode.invalidInput, '该账号已作为代签账号导入，不能再作为本人登录');
    }
    await ensureRoomFor(phoneNumber);
    final localCode = await chaoxingLocalDeviceCode(device);
    final client = await ChaoxingClient.signIn(
      http: _http(ChaoxingCookieJar()),
      phoneNumber: phoneNumber,
      password: password,
      deviceCode: localCode.isEmpty ? chaoxingDeviceCode() : localCode,
      device: device,
    );
    final existing = await record(client.phoneNumber);
    _keepUnit(client, existing);
    await _persist(client, isOtherUser: false, createdAt: existing?.createdAt, deviceCodeBound: localCode.isNotEmpty);
    return client.account!;
  }

  Future<ChaoxingClient?> clientFor(String phoneNumber) async {
    final stored = await record(phoneNumber);
    if (stored == null) return null;
    final http = _http(ChaoxingCookieJar(session: await vault.readCookies(phoneNumber)));
    return ChaoxingClient(
      http: http,
      phoneNumber: phoneNumber,
      encryptedPassword: await vault.readPassword(phoneNumber) ?? '',
      deviceCode: stored.deviceCode,
      device: device,
      account: ChaoxingAccount(
        phoneNumber: phoneNumber,
        uid: stored.uid,
        puid: stored.puid,
        fid: stored.fid,
        name: stored.name,
        deviceCode: stored.deviceCode,
        schoolName: stored.schoolName,
        clientId: stored.clientId.isEmpty ? null : stored.clientId,
        units: stored.units,
      ),
    );
  }

  // 会话过期时自动重登一次并重放这次请求；再失败就交给用户重新登录（或修复）。
  Future<T> run<T>(ChaoxingClient client, Future<T> Function() action) async {
    try {
      return await action();
    } on ChaoxingFailure catch (error, stack) {
      if (error.code != ChaoxingFailureCode.sessionExpired) rethrow;
      try {
        await _reLogin(client);
      } on ChaoxingFailure catch (reLoginFailure) {
        campusLog('[Chaoxing] action=re_login errorType=${reLoginFailure.code.name}');
        // 密码不再被接受才是真的过期（要修复）；网络类失败照实报，稍后重试即可。
        if (reLoginFailure.code != ChaoxingFailureCode.sessionExpired) rethrow;
        Error.throwWithStackTrace(error, stack);
      }
      return await action();
    }
  }

  // 同一会话的并发请求（刷新时几门课一起拉）同时过期时只重登一次，大家等同一次的结果。
  final _reLogins = <ChaoxingClient, Future<void>>{};

  Future<void> _reLogin(ChaoxingClient client) => _reLogins[client] ??= () async {
    try {
      await client.reLogin();
      // 与 refreshAccount 同理：重登途中账号被删了就不写回会话。
      if (await record(client.phoneNumber) != null) await vault.writeCookies(client.phoneNumber, client.http.cookies.session);
    } finally {
      _reLogins.remove(client);
    }
  }();

  // 补一次用户信息：clientId 与群聊密码都只在这里下发；clientId 记进库里，签人脸时要用。
  Future<void> refreshAccount(ChaoxingClient client) => run(client, () async {
    client.account = await client.loadAccount();
    // 记录在响应之后再读：后台刷新期间用户可能切换了学校单位，按最新的记录恢复所选单位，
    // 别拿刷新前的快照把用户刚选的单位覆盖回去。
    final existing = await record(client.phoneNumber);
    // 刷新期间账号可能已被删除：先确认记录还在再写会话，不能把已删账号的 cookie 写回安全存储。
    if (existing == null) return;
    _keepUnit(client, existing);
    await vault.writeCookies(client.phoneNumber, client.http.cookies.session);
    final account = client.account!;
    await store.putAccount(
      existing.change(
        fid: account.fid,
        schoolName: account.schoolName,
        clientId: account.clientId ?? existing.clientId,
        units: account.units,
      ),
    );
  });

  // 对方改了密码或会话彻底失效时，重新输一次密码修复，账号的设备码与设置都不变。
  Future<void> repair(ChaoxingClient client, String password) async {
    ChaoxingClient.validatePassword(password);
    final previous = client.encryptedPassword;
    client.encryptedPassword = await chaoxingEncrypt(password);
    try {
      await client.login();
    } on ChaoxingFailure {
      client.encryptedPassword = previous;
      rethrow;
    }
    final existing = await record(client.phoneNumber);
    client.account = await client.loadAccount();
    _keepUnit(client, existing);
    await _persist(
      client,
      isOtherUser: existing?.isOtherUser ?? false,
      name: existing?.isOtherUser == true ? existing!.name : null,
      createdAt: existing?.createdAt,
      deviceCodeBound: existing?.deviceCodeBound ?? false,
    );
  }

  // 切换学校单位：改会话里的 fid 并记下来，之后的课程列表与签到都按这个单位走。
  Future<void> selectUnit(ChaoxingClient client, ChaoxingUnit unit) async {
    final account = client.account!;
    if (!account.units.any((item) => item.fid == unit.fid)) {
      throw const ChaoxingFailure(ChaoxingFailureCode.invalidInput, '请选择账号所属的学校单位');
    }
    client.account = account.change(fid: unit.fid, schoolName: unit.name);
    client.applyUnit(unit.fid);
    await vault.writeCookies(client.phoneNumber, client.http.cookies.session);
    final existing = await record(client.phoneNumber);
    if (existing != null) await store.putAccount(existing.change(fid: unit.fid, schoolName: unit.name));
  }

  // 导入别人的代签凭据：密文密码与对方设备码进安全存储，再登录一次拿真实的 uid/fid 与昵称。
  // 带上对方的设备码，用它签到时学习通不会提示「更换了签到设备」；对方附带的人脸照片也一并记下。
  Future<ChaoxingAccountRecord> importOther(ChaoxingCredentialPack pack) async {
    final existing = await record(pack.phoneNumber);
    if (existing != null && !existing.isOtherUser) {
      throw const ChaoxingFailure(ChaoxingFailureCode.invalidInput, '这是你自己的账号，不用导入代签码');
    }
    await ensureRoomFor(pack.phoneNumber);
    final client = ChaoxingClient(
      http: _http(ChaoxingCookieJar()),
      phoneNumber: pack.phoneNumber,
      encryptedPassword: pack.encryptedPassword,
      deviceCode: pack.deviceCode.isEmpty ? (existing?.deviceCode ?? chaoxingDeviceCode()) : pack.deviceCode,
      device: device,
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
    _keepUnit(client, existing);
    await _persist(
      client,
      isOtherUser: true,
      name: pack.name,
      createdAt: existing?.createdAt,
      deviceCodeBound: pack.deviceCode.isNotEmpty || (existing?.deviceCodeBound ?? false),
    );
    for (final objectId in pack.faceObjectIds.reversed) {
      await store.putFaceImage(pack.phoneNumber, objectId);
    }
    client.close();
    return (await record(pack.phoneNumber))!;
  }

  Future<void> forget(String phoneNumber) async {
    await store.removeAccount(phoneNumber);
    await vault.delete(phoneNumber);
  }

  // 重新登录或补用户信息后，所选学校单位还在账号的单位里就保留，不在了退回主单位。
  void _keepUnit(ChaoxingClient client, ChaoxingAccountRecord? existing) {
    final account = client.account!;
    final kept = account.units.where((unit) => unit.fid == existing?.fid).firstOrNull;
    if (kept == null) return;
    client.account = account.change(fid: kept.fid, schoolName: kept.name);
    client.applyUnit(kept.fid);
  }

  Future<void> _persist(
    ChaoxingClient client, {
    required bool isOtherUser,
    required bool deviceCodeBound,
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
        units: account.units,
        deviceCodeBound: deviceCodeBound,
      ),
    );
  }
}
