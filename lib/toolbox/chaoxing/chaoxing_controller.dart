import 'package:flutter/foundation.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_accounts.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_activity.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_captcha.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_face.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_im.dart';
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

  // 还能签的活动（接口把课程的全部历史活动一起给回来，这里只留未结束的）。
  List<ChaoxingActivity> activities = const [];

  // 已结束的活动，给「往期签到」入口用。
  List<ChaoxingActivity> pastActivities = const [];
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
      pastActivities = const [];
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
    String? faceObjectId,
    String? faceEnc,
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
        faceObjectId: faceObjectId,
        faceEnc: faceEnc,
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

  // 群聊里的签到：先换环信令牌、列群、拉漫游，再按附件拼出活动；类型名认不出来的去详情里问。
  Future<List<ChaoxingActivity>> loadGroupActivities() async {
    final client = _requireClient();
    // 群聊凭证只在登录响应里下发，恢复出来的账号要先补一次用户信息（这类密钥不落库）。
    if (client.account!.imPassword.isEmpty) {
      await accounts.run(client, () async {
        client.account = await client.loadAccount();
        return true;
      });
    }
    final found = await accounts.run(client, () => chaoxingImActivities(client, groupLimit: chaoxingImGroupLimit));
    final activities = <ChaoxingActivity>[];
    var failures = 0;
    for (final item in found) {
      var signType = chaoxingSignTypeOfAtypeName(item.atypeName);
      ChaoxingActiveInfo? info;
      if (signType == null) {
        // 群附件里的类型名认不出来时要去详情里问；单条问不到就跳过这一条，不能让整页失败
        // （与 _loadActivities 一个口径：个别活动读不到不影响其余）。
        try {
          final detail = await accounts.run(client, () => chaoxingActiveInfo(client, item.activeId));
          info = detail;
          signType = detail.signType;
        } catch (failure, stack) {
          campusLog('[Chaoxing] action=group_detail errorType=${failure.runtimeType} activeId=${item.activeId}\n$stack');
          failures++;
          continue;
        }
      }
      if (signType == null) continue;
      final resolved = signType;
      activities.add(
        ChaoxingActivity(
          activeId: item.activeId,
          courseId: item.courseId,
          classId: item.classId,
          title: item.title.isEmpty ? resolved.label : item.title,
          subtitle: item.courseName.isEmpty ? item.groupName : item.courseName,
          signType: signType,
          startTime: info?.startTime ?? DateTime.now().toUtc(),
          endTime: info?.endTime,
          status: 0,
          userStatus: 0,
          ext: '',
        ),
      );
    }
    // 一条都没读出来而且有失败，说明是网络或上游的问题，不能显示成「群里现在没有能签到的活动」。
    if (activities.isEmpty && failures > 0) {
      throw const ChaoxingFailure(ChaoxingFailureCode.network, '群聊里的签到没读全，请稍后重试');
    }
    return activities;
  }

  // 人脸识别：优先用本机记着的照片，其次用学习通里存的那张；都没有就让用户先选一张。
  Future<({String objectId, String faceEnc})> prepareFace(ChaoxingActivity activity, {String? objectId}) async {
    final client = _requireClient();
    final chosen = objectId ?? await _preferredFaceObjectId(client);
    if (chosen == null) {
      throw const ChaoxingFailure(ChaoxingFailureCode.faceRequired, '这场签到要人脸照片，请先选一张');
    }
    final faceEnc = await accounts.run(client, () => chaoxingFaceEnc(client, activeId: activity.activeId, objectId: chosen));
    return (objectId: chosen, faceEnc: faceEnc);
  }

  Future<String?> _preferredFaceObjectId(ChaoxingClient client) async {
    final stored = await accounts.store.faceImages(client.phoneNumber);
    if (stored.isNotEmpty) return stored.first;
    // clientId 是签名要用的，库里没有就先补一次（会话过期时 run 会先重登）。
    if ((client.account?.clientId ?? '').isEmpty) {
      await accounts.run(client, () async {
        client.account = await client.loadAccount();
        return true;
      });
      await accounts.rememberClientId(client.phoneNumber, client.account?.clientId ?? '');
    }
    final profile = await accounts.run(client, () => chaoxingProfileFaceObjectId(client));
    if (profile == null) return null;
    await accounts.store.putFaceImage(client.phoneNumber, profile);
    return profile;
  }

  // 人脸照片不做裁剪旋转（要认得出人），上传后记下来供以后复用。
  Future<String> uploadFacePhoto(List<int> bytes) async {
    final client = _requireClient();
    final objectId = await accounts.run(client, () => chaoxingUploadPhoto(client, bytes: bytes));
    await accounts.store.putFaceImage(client.phoneNumber, objectId);
    return objectId;
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
    // [人工决策-2026-10-06 23:24:35] 「进行中的签到」只列未结束的：接口会把课程的全部历史活动
    // 一起给回来（实测 195 条里绝大多数已结束），已结束的点了也签不上，堆在这里既对不上标题、
    // 又让人找不到真正能签的那一场。已结束的另走「往期签到」入口，不再混在同一个列表里。
    collected.sort((first, second) => second.startTime.compareTo(first.startTime));
    activities = [for (final activity in collected) if (!activity.ended) activity];
    pastActivities = [for (final activity in collected) if (activity.ended) activity];
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
