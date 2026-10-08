import 'dart:convert';
import 'dart:math';

import 'package:superxd/toolbox/chaoxing/chaoxing_crypto.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_device.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_http.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';

const chaoxingLoginUri = 'https://passport2.chaoxing.com/fanyalogin';
const chaoxingUserInfoUri = 'https://sso.chaoxing.com/apis/login/userLogin4Uname.do';
const chaoxingPasswordMinLength = 8;
const chaoxingPasswordMaxLength = 16;

// [人工决策-2026-10-06 23:02:25] 登录与用户信息这两个接口单独用 30 秒超时：实测它们的响应在
// 2.4–30.5 秒之间波动（同刻 curl 与纯 dart:io 请求对照一致，不是客户端问题），按默认 15 秒
// 会在真实网络上偶发「请求超时」；登录是低频关键操作，值得多等。列表、签到等交互密集的接口
// 仍用 chaoxing_http 的默认超时。
const chaoxingAccountTimeout = Duration(seconds: 30);

// 登录表单固定字段；手机号与密码是 AES 密文，按表单编码提交。
String chaoxingLoginBody({
  required String encryptedPhone,
  required String encryptedPassword,
}) => chaoxingFormBody({
  'fid': '-1',
  'uname': encryptedPhone,
  'password': encryptedPassword,
  'refer': 'https://i.chaoxing.com',
  't': 'true',
  'forbidotherlogin': '0',
  'validate': '',
  'doubleFactorLogin': '0',
  'independentId': '0',
  'independentNameId': '0',
});

// 固定随机设备码：取不到 OAID 时用，只要求稳定且够长；sha256 摘要拼接后 Base64，与学习通客户端同一个形状。
String chaoxingDeviceCode([Random? random]) {
  final source = random ?? Random.secure();
  final digest = chaoxingSha256Bytes(List<int>.generate(64, (_) => source.nextInt(256)));
  return base64.encode([...digest, ...digest]);
}

// 一个学习通账号的会话：cookie 在 http 的 jar 里，凭据在安全存储里，这里只负责协议。
class ChaoxingClient {
  ChaoxingClient({
    required this.http,
    required this.phoneNumber,
    required this.encryptedPassword,
    required this.deviceCode,
    this.account,
    this.device,
  });

  final ChaoxingHttp http;
  final String phoneNumber;

  // 对方改了密码后可以重输一次修复，所以不是 final。
  String encryptedPassword;

  // 设备信息来源；为空时用户信息接口退回不带设备信息的 GET（拿不到人脸签名要的 clientId）。
  final ChaoxingDeviceProbe? device;

  // 设备码会随导入他人账号而改变，所以不是 final。
  String deviceCode;
  ChaoxingAccount? account;

  // 本次会话里查到的所在班级号（签到前检查用，每人每次都拉整张课程表太重）；重新登录后作废。
  Set<int>? classIds;

  static void validatePassword(String password) {
    if (password.isEmpty) {
      throw const ChaoxingFailure(ChaoxingFailureCode.invalidInput, '密码不能为空');
    }
    if (password.length < chaoxingPasswordMinLength || password.length > chaoxingPasswordMaxLength) {
      throw const ChaoxingFailure(ChaoxingFailureCode.invalidInput, '密码位数应在 8-16 位之间');
    }
  }

  static Future<ChaoxingClient> signIn({
    required ChaoxingHttp http,
    required String phoneNumber,
    required String password,
    String? deviceCode,
    ChaoxingDeviceProbe? device,
  }) async {
    final trimmed = phoneNumber.trim();
    if (trimmed.isEmpty) {
      throw const ChaoxingFailure(ChaoxingFailureCode.invalidInput, '请输入手机号');
    }
    validatePassword(password);
    final client = ChaoxingClient(
      http: http,
      phoneNumber: trimmed,
      encryptedPassword: await chaoxingEncrypt(password),
      deviceCode: deviceCode ?? chaoxingDeviceCode(),
      device: device,
    );
    await client.login();
    client.account = await client.loadAccount();
    return client;
  }

  Future<void> login() async {
    final response = await http.postForm(
      Uri.parse(chaoxingLoginUri),
      chaoxingLoginBody(
        encryptedPhone: await chaoxingEncrypt(phoneNumber),
        encryptedPassword: encryptedPassword,
      ),
      timeout: chaoxingAccountTimeout,
    );
    final result = chaoxingJson(response.body);
    if (result['status'] != true) {
      final message = chaoxingString(result['msg2']).trim();
      throw ChaoxingFailure(ChaoxingFailureCode.login, message.isEmpty ? '登录失败，请核对账号密码' : message);
    }
    classIds = null;
    // 登录响应会把 fid 换回主单位；选了别的学校单位时改回所选的，课程列表才对得上。
    final selected = account?.fid;
    if (selected != null && selected != 0) applyUnit(selected);
  }

  // 只改会话里已有的 fid，不凭空加。
  void applyUnit(int fid) {
    if (http.cookies['fid'] != null) http.cookies.set('fid', '$fid');
  }

  // 会话过期后拿密文密码再登一次；账号密码不再被接受时按过期处理，由用户重新登录（修复）。
  // 超时、断网等其余失败原样抛出，不能把「网络不好」说成「登录已过期」。
  Future<void> reLogin() async {
    try {
      await login();
    } on ChaoxingFailure catch (error, stack) {
      if (error.code != ChaoxingFailureCode.login) rethrow;
      Error.throwWithStackTrace(const ChaoxingFailure(ChaoxingFailureCode.sessionExpired, chaoxingSessionExpiredMessage), stack);
    }
  }

  // 用户信息接口按上传的设备信息下发人脸签名要的 clientId：带得上设备信息就 POST，带不上退回 GET（学习通客户端同样如此）。
  Future<ChaoxingAccount> loadAccount() async {
    final data = await chaoxingEncryptedDeviceInfo(device, http.profile.packageName);
    final response = data == null
        ? await http.get(Uri.parse(chaoxingUserInfoUri), timeout: chaoxingAccountTimeout)
        : await http.postForm(Uri.parse(chaoxingUserInfoUri), chaoxingFormBody({'data': data}), timeout: chaoxingAccountTimeout);
    final message = chaoxingJson(response.body)['msg'];
    if (message is! Map) {
      throw const ChaoxingFailure(ChaoxingFailureCode.sessionExpired, chaoxingSessionExpiredMessage);
    }
    final info = message.cast<String, Object?>();
    final uid = chaoxingInt(info['uid']);
    if (uid == 0) {
      throw const ChaoxingFailure(ChaoxingFailureCode.sessionExpired, chaoxingSessionExpiredMessage);
    }
    final imAccount = (info['accountInfo'] as Map?)?['imAccount'] as Map?;
    final clientId = chaoxingString(info['clientId']);
    final units = chaoxingUnits(info);
    return ChaoxingAccount(
      phoneNumber: phoneNumber,
      uid: uid,
      puid: chaoxingInt(info['puid'], fallback: uid),
      fid: units.first.fid,
      name: chaoxingString(info['name'], fallback: phoneNumber),
      deviceCode: deviceCode,
      schoolName: units.first.name,
      photoUrl: chaoxingString(info['pic']).replaceFirst('http://', 'https://'),
      imPassword: chaoxingString(imAccount?['password']),
      clientId: clientId.isEmpty ? null : clientId,
      units: units,
    );
  }

  void close() => http.close();
}

const chaoxingUnknownSchool = '未知学校';

// 学校单位：主单位在最前（fid 与 schoolname），unitConfigInfos 里的其余单位按出现顺序跟在后面；
// 同一个 fid 只留一条，主单位没名字时用后面给的名字补上。
List<ChaoxingUnit> chaoxingUnits(Map<String, Object?> info) {
  final names = <int, String>{};
  String nameOf(Object? value) => chaoxingString(value).trim().isEmpty ? chaoxingUnknownSchool : chaoxingString(value).trim();
  names[chaoxingInt(info['fid'])] = nameOf(info['schoolname']);
  final configs = info['unitConfigInfos'];
  if (configs is List) {
    for (final config in configs) {
      if (config is! Map || config['fid'] == null) continue;
      final fid = chaoxingInt(config['fid']);
      if (!names.containsKey(fid) || names[fid] == chaoxingUnknownSchool) names[fid] = nameOf(config['schoolname']);
    }
  }
  return [for (final entry in names.entries) ChaoxingUnit(fid: entry.key, name: entry.value)];
}
