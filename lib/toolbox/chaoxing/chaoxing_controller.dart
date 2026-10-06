import 'package:flutter/foundation.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_accounts.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_activity.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_captcha.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_credential_pack.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_client.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_location.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_pack_client.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_photo.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_qrcode.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_signer.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_store.dart';

enum ChaoxingStatus { loading, signedOut, ready }

class ChaoxingController extends ChangeNotifier {
  ChaoxingController({required this.accounts, this.hub});
  final ChaoxingAccounts accounts;

  // 代签凭据包的中转；没配中转时为 null，出示与扫码导入都不显示。
  final ChaoxingPackHub? hub;

  // 一次刷新最多并发三个课程请求，课程多时也不至于把刷新拖太久。
  static const refreshConcurrency = 3;

  ChaoxingStatus status = ChaoxingStatus.loading;
  List<ChaoxingAccountRecord> accountList = const [];
  ChaoxingAccountRecord? current;
  List<ChaoxingCourse> courses = const [];
  List<ChaoxingActivity> activities = const [];
  List<ChaoxingSavedLocation> locations = const [];
  String? error;
  bool busy = false;
  int? signingActiveId;
  ChaoxingClient? _client;
  bool _disposed = false;

  ChaoxingAccount? get account => _client?.account;

  Future<void> initialize() async {
    status = ChaoxingStatus.loading;
    error = null;
    _notify();
    try {
      accountList = await accounts.list();
      locations = await accounts.store.locations();
      if (accountList.isEmpty) {
        status = ChaoxingStatus.signedOut;
        _notify();
        return;
      }
      await _open(accountList.first);
    } catch (failure, stack) {
      _fail('load', failure, stack, '账号读取失败，请重试');
    }
  }

  Future<void> signIn(String phoneNumber, String password) async {
    if (busy) return;
    busy = true;
    error = null;
    _notify();
    try {
      final account = await accounts.signIn(phoneNumber: phoneNumber, password: password);
      final stored = await accounts.record(account.phoneNumber);
      if (stored == null) {
        throw const ChaoxingFailure(ChaoxingFailureCode.server, '账号保存失败，请重试');
      }
      accountList = await accounts.list();
      await _open(stored);
    } catch (failure, stack) {
      _fail('sign_in', failure, stack, '登录未完成，请检查网络后重试');
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> select(ChaoxingAccountRecord record) async {
    if (busy) return;
    busy = true;
    error = null;
    _notify();
    try {
      await _open(record);
    } catch (failure, stack) {
      _fail('select', failure, stack, '切换账号未完成，请重试');
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> removeAccount(ChaoxingAccountRecord record) async {
    try {
      await accounts.forget(record.phoneNumber);
      _client?.close();
      _client = null;
      current = null;
      activities = const [];
      courses = const [];
      accountList = await accounts.list();
      if (accountList.isEmpty) {
        status = ChaoxingStatus.signedOut;
      } else {
        await _open(accountList.first);
      }
    } catch (failure, stack) {
      _fail('remove_account', failure, stack, '删除账号未完成，请重试');
    }
    _notify();
  }

  Future<void> refresh() async {
    if (busy || _client == null) return;
    busy = true;
    error = null;
    _notify();
    try {
      await _loadActivities();
    } catch (failure, stack) {
      _fail('refresh', failure, stack, '刷新未完成，请检查网络后重试');
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<ChaoxingActiveInfo> activeInfo(ChaoxingActivity activity) async {
    final client = _requireClient();
    return accounts.run(client, () => chaoxingActiveInfo(client, activity.activeId));
  }

  // 拍照签到的照片先裁好传上云盘，拿 objectId；验证码重试时不用重传。
  Future<String> uploadPhoto(List<int> photoBytes) async {
    final client = _requireClient();
    final photo = await compute(chaoxingStylizePhoto, Uint8List.fromList(photoBytes));
    return accounts.run(client, () => chaoxingUploadPhoto(client, bytes: photo));
  }

  Future<ChaoxingSignResult> sign(
    ChaoxingActivity activity, {
    String? signCode,
    ChaoxingLocation? location,
    String? photoObjectId,
    ChaoxingQrCode? qrCode,
    String? captchaValidate,
    String? enc2,
  }) async {
    final client = _requireClient();
    signingActiveId = activity.activeId;
    _notify();
    try {
      final presign = await accounts.run(client, () => chaoxingPreSign(client, activity));
      if (presign == ChaoxingPreSignStatus.alreadySigned) {
        throw const ChaoxingFailure(ChaoxingFailureCode.alreadySigned, '这场签到已经完成了');
      }
      if (presign == ChaoxingPreSignStatus.expired) {
        throw const ChaoxingFailure(ChaoxingFailureCode.expired, '签到已截止');
      }
      if (qrCode != null &&
          await accounts.run(client, () => chaoxingQrCodeExpired(client, code: qrCode, activeId: activity.activeId))) {
        throw const ChaoxingFailure(ChaoxingFailureCode.qrCodeExpired, '二维码已过期，请重新扫描');
      }
      final submission = ChaoxingSignSubmission(
        activity: activity,
        activeId: qrCode?.activeId,
        signCode: signCode,
        location: location,
        enc: qrCode?.enc,
        objectId: photoObjectId,
        captchaValidate: captchaValidate,
        enc2: enc2,
      );
      late ChaoxingSignResult result;
      try {
        result = await accounts.run(client, () => chaoxingSubmit(client, submission));
      } on ChaoxingFailure catch (failure) {
        if (failure.code != ChaoxingFailureCode.wrongPosition || location == null) rethrow;
        result = await accounts.run(client, () => chaoxingSubmit(client, submission.change(tightenLocation: true)));
      }
      await accounts.store.addSignRecord(
        ChaoxingSignRecord(
          phoneNumber: client.phoneNumber,
          activeId: activity.activeId,
          courseId: activity.courseId,
          signType: activity.signType,
          result: result.late ? 'late' : 'success',
          createdAt: DateTime.now().toUtc(),
        ),
      );
      return result;
    } finally {
      signingActiveId = null;
      _notify();
    }
  }

  // 从主签到跳到它关联的签退活动（或反过来）：详情里拿类型与时间重组一个活动。
  Future<ChaoxingActivity> relatedActivity(ChaoxingActivity current, int activeId) async {
    final client = _requireClient();
    final info = await accounts.run(client, () => chaoxingActiveInfo(client, activeId));
    final signType = info.signType;
    if (signType == null) {
      throw const ChaoxingFailure(ChaoxingFailureCode.unsupported, '这个活动暂不支持签到');
    }
    return ChaoxingActivity(
      activeId: activeId,
      courseId: current.courseId,
      classId: current.classId,
      title: info.title.isEmpty ? signType.label : info.title,
      subtitle: current.subtitle,
      signType: signType,
      startTime: info.startTime ?? DateTime.now().toUtc(),
      endTime: info.endTime,
      status: 0,
      userStatus: 0,
      ext: '',
    );
  }

  Future<ChaoxingCaptchaPuzzle> captchaPuzzle(ChaoxingActivity activity) async {
    final client = _requireClient();
    return accounts.run(
      client,
      () => chaoxingCaptchaPuzzle(client, referer: _preSignUri(client, activity)),
    );
  }

  Future<ChaoxingCaptchaAnswer> solveCaptcha(
    ChaoxingActivity activity,
    ChaoxingCaptchaPuzzle puzzle,
    double position,
  ) async {
    final client = _requireClient();
    return accounts.run(
      client,
      () => chaoxingCaptchaVerify(client, puzzle: puzzle, position: position, referer: _preSignUri(client, activity)),
    );
  }

  Future<Uint8List> captchaImage(String url) async {
    final client = _requireClient();
    return accounts.run(client, () => chaoxingCaptchaImage(client, url));
  }

  Future<bool> checkSignCode(ChaoxingActivity activity, String signCode) async {
    final client = _requireClient();
    return accounts.run(client, () => chaoxingCheckSignCode(client, activeId: activity.activeId, signCode: signCode));
  }

  // 出示代签码：把当前账号封成凭据包，密文放到中转，二维码里只有取件号与一次性密钥。
  Future<String> createCredentialTicket() async {
    final client = _requireClient();
    final packHub = hub;
    if (packHub == null || !packHub.available) {
      throw const ChaoxingFailure(ChaoxingFailureCode.unavailable, '还没有配置中转服务，代签码用不了');
    }
    final password = await accounts.vault.readPassword(client.phoneNumber);
    if (password == null || password.isEmpty) {
      throw const ChaoxingFailure(ChaoxingFailureCode.sessionExpired, '请先重新登录这个账号再出示代签码');
    }
    final sealed = await sealChaoxingCredentialPack(
      ChaoxingCredentialPack(
        phoneNumber: client.phoneNumber,
        encryptedPassword: password,
        name: client.account!.name,
        deviceCode: client.deviceCode,
      ),
    );
    final pickupId = await packHub.submit(sealed.cipherText);
    return encodeChaoxingPackTicket(ChaoxingPackTicket(pickupId: pickupId, key: sealed.key));
  }

  // 导入别人的代签码：取件、解密、用对方的设备码登录一次确认，再按他人账号存进本机。
  Future<ChaoxingAccountRecord> importCredentialTicket(String raw) async {
    final packHub = hub;
    if (packHub == null || !packHub.available) {
      throw const ChaoxingFailure(ChaoxingFailureCode.unavailable, '还没有配置中转服务，代签码用不了');
    }
    final ticket = decodeChaoxingPackTicket(raw);
    if (ticket == null) {
      throw const ChaoxingFailure(ChaoxingFailureCode.invalidInput, '这不是学习通代签二维码');
    }
    final cipherText = await packHub.pickup(ticket.pickupId);
    final pack = await openChaoxingCredentialPack(ChaoxingSealedPack(key: ticket.key, cipherText: cipherText));
    final record = await accounts.importOther(pack);
    accountList = await accounts.list();
    _notify();
    return record;
  }

  Future<void> saveLocation(String label, ChaoxingLocation location) async {
    await accounts.store.putLocation(label, location);
    locations = await accounts.store.locations();
    _notify();
  }

  Future<void> forgetLocation(int id) async {
    await accounts.store.removeLocation(id);
    locations = await accounts.store.locations();
    _notify();
  }

  Future<void> _open(ChaoxingAccountRecord record) async {
    _client?.close();
    _client = null;
    final client = await accounts.clientFor(record.phoneNumber);
    if (client == null) {
      throw const ChaoxingFailure(ChaoxingFailureCode.sessionExpired, '账号已不存在，请重新登录');
    }
    _client = client;
    current = record;
    status = ChaoxingStatus.ready;
    _notify();
    await _loadActivities();
  }

  Future<void> _loadActivities() async {
    final client = _requireClient();
    courses = await accounts.run(client, () => chaoxingCourses(client));
    var failures = 0;
    final collected = <ChaoxingActivity>[];
    for (var index = 0; index < courses.length; index += refreshConcurrency) {
      final chunk = courses.skip(index).take(refreshConcurrency);
      final results = await Future.wait(
        chunk.map((course) async {
          try {
            return await accounts.run(client, () => chaoxingActivities(client, course));
          } catch (failure, stack) {
            campusLog('[Chaoxing] action=activities errorType=${failure.runtimeType}\n$stack');
            failures++;
            return const <ChaoxingActivity>[];
          }
        }),
      );
      for (final result in results) {
        collected.addAll(result);
      }
    }
    if (collected.isEmpty && failures > 0) {
      throw const ChaoxingFailure(ChaoxingFailureCode.network, '签到活动没读到，请稍后重试');
    }
    collected.sort((first, second) => second.startTime.compareTo(first.startTime));
    activities = collected;
  }

  Uri _preSignUri(ChaoxingClient client, ChaoxingActivity activity) =>
      chaoxingPreSignRequestUri(activity: activity, account: client.account!);

  ChaoxingClient _requireClient() =>
      _client ?? (throw const ChaoxingFailure(ChaoxingFailureCode.sessionExpired, '登录已过期，请重新登录'));

  void _fail(String action, Object failure, StackTrace stack, String fallback) {
    if (failure is! ChaoxingFailure) {
      campusLog('[Chaoxing] action=$action errorType=${failure.runtimeType}\n$stack');
    }
    error = failure is ChaoxingFailure ? failure.message : fallback;
    if (_client == null && accountList.isEmpty) status = ChaoxingStatus.signedOut;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _client?.close();
    super.dispose();
  }
}
