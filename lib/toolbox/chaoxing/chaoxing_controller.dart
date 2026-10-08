import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:pool/pool.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_accounts.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_activity.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_batch.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_captcha.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_client.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_delegate_controller.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_face_controller.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_http.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_im.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_lessons.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_location.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_pack_client.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_qrcode.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_signer.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_sign_flow.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_store.dart';
import 'package:superxd/toolbox/toolbox_models.dart';

enum ChaoxingStatus { loading, signedOut, ready }

// 课程页的一组课：同名课程（多个班）合并成一组。
class ChaoxingCourseGroup {
  const ChaoxingCourseGroup({required this.name, required this.courses, required this.pinned});
  final String name;
  final List<ChaoxingCourse> courses;
  final bool pinned;
}

class ChaoxingController extends ChangeNotifier {
  ChaoxingController({required this.accounts, this.hub, this.filePublisher});
  final ChaoxingAccounts accounts;

  // 代签凭据包的中转；没配中转时为 null，出示与扫码导入都不显示。
  final ChaoxingPackHub? hub;
  // 公共下载目录的文件导出（人脸照片保存到本机用）；为空时保存入口不可用（测试环境）。
  final ToolboxFilePublisher Function()? filePublisher;

  // 一次刷新最多并发三个课程请求，课程多时也不至于把刷新拖太久。
  static const refreshConcurrency = 3;


  ChaoxingStatus status = ChaoxingStatus.loading;
  List<ChaoxingAccountRecord> accountList = const [];
  ChaoxingAccountRecord? current;
  List<ChaoxingCourse> courses = const [];

  // 进行中的签到（活动列表 status 为 1 的）。
  List<ChaoxingActivity> activities = const [];

  // 已结束的活动，给「往期签到」入口用；照样能签，签到页会提示可能记迟到。
  List<ChaoxingActivity> pastActivities = const [];

  // 按学习通课表推断的「可能正在签到」：当前节次的课里刚发起（20 分钟内）的进行中签到。
  List<ChaoxingActivity> lessonActivities = const [];
  Set<int> pinnedClassIds = const {};
  List<ChaoxingSavedLocation> locations = const [];
  String? error;
  bool busy = false;

  // 正在拉课程与活动：列表为空时显示加载中，而不是「没有可签到的活动」。
  bool loadingActivities = false;
  ChaoxingClient? _client;
  final _clients = <String, ChaoxingClient>{};
  bool _disposed = false;

  // 账号代次：每打开一个账号加一。异步结果回来时代次已变（期间切了账号），就丢弃不写，
  // 免得旧账号的列表或错误落到新账号的界面上（同今天页的 _readGeneration）。
  int _generation = 0;

  ChaoxingAccount? get account => _client?.account;
  ChaoxingClientProfile get profile => accounts.profile;

  // 签到对象：当前账号排第一并默认勾上，其余账号默认不勾。
  List<ChaoxingSignTarget> signTargets() => [
    if (current != null) ChaoxingSignTarget(current!, selected: true),
    for (final record in accountList)
      if (record.phoneNumber != current?.phoneNumber) ChaoxingSignTarget(record),
  ];

  Future<void> initialize() async {
    status = ChaoxingStatus.loading;
    error = null;
    _notify();
    try {
      await accounts.loadProfile();
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
      _dropClient(stored.phoneNumber);
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

  // 退出登录：只关当前会话回到登录页，账号数据（凭据、人脸照片、设置、收藏）全部保留，
  // 与删除账号不同；下次登录同一账号（或切换回来）直接复用。
  Future<void> signOut() async {
    await _maintenance;
    _generation++;
    _closeSessions();
    current = null;
    activities = const [];
    pastActivities = const [];
    lessonActivities = const [];
    courses = const [];
    status = ChaoxingStatus.signedOut;
    _notify();
  }

  // 备注名（多账号管理里改，显示时优先于昵称）。
  Future<void> renameAccount(ChaoxingAccountRecord record, String label) async {
    await accounts.store.renameAccount(record.phoneNumber, label);
    accountList = await accounts.list();
    if (current?.phoneNumber == record.phoneNumber) current = await accounts.record(record.phoneNumber);
    _notify();
  }

  // 手动排序：把拖完的顺序写回并刷新列表。
  Future<void> reorderAccounts(List<ChaoxingAccountRecord> ordered) async {
    await accounts.store.reorderAccounts([for (final record in ordered) record.phoneNumber]);
    accountList = await accounts.list();
    _notify();
  }

  Future<void> removeAccount(ChaoxingAccountRecord record) async {
    try {
      // 等后台刷新落定再删：它跨过删除会把这个账号的会话写回安全存储。
      await _maintenance;
      await accounts.forget(record.phoneNumber);
      _dropClient(record.phoneNumber);
      if (current?.phoneNumber == record.phoneNumber) {
        _generation++;
        _client?.close();
        _client = null;
        current = null;
        activities = const [];
        pastActivities = const [];
        lessonActivities = const [];
        courses = const [];
      }
      accountList = await accounts.list();
      if (accountList.isEmpty) {
        status = ChaoxingStatus.signedOut;
      } else if (current == null) {
        await _open(accountList.first);
      }
    } catch (failure, stack) {
      _fail('remove_account', failure, stack, '删除账号未完成，请重试');
    }
    _notify();
  }

  // 当前账号的头像（用户信息里下发的云盘地址，只在内存；没有为空串）。
  String get currentPhoto => _client?.account?.photoUrl ?? '';

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

  // 给签到对象开会话：当前账号直接用，其余账号按需打开并留着，整页关掉时一起关。
  Future<ChaoxingClient> clientOf(ChaoxingAccountRecord record) async {
    if (record.phoneNumber == current?.phoneNumber) return _requireClient();
    final opened = _clients[record.phoneNumber];
    if (opened != null) return opened;
    final client = await accounts.clientFor(record.phoneNumber);
    if (client == null) {
      throw const ChaoxingFailure(ChaoxingFailureCode.sessionExpired, '账号已不存在，请重新导入');
    }
    _clients[record.phoneNumber] = client;
    return client;
  }

  // 人脸照片（列表、上传、预览、保存到本机、默认照片重处理）与代签码（出示、取件导入）各自一块，
  // 按需拿会话，不反向依赖本页面状态。
  late final faces = ChaoxingFaceController(accounts: accounts, clientOf: clientOf, currentClient: _requireClient, filePublisher: filePublisher);
  late final delegate = ChaoxingDelegateController(accounts: accounts, hub: hub, currentClient: _requireClient);

  // 完整签到流程在 chaoxing_sign_flow.dart：检查、拍照上传、人脸、提交与验证码/换码/位置收紧重试。
  late final signFlow = ChaoxingSignFlow(
    ChaoxingSignContext(
      clientOf: clientOf,
      currentPhone: () => current?.phoneNumber,
      run: accounts.run,
      faceImages: accounts.store.faceImages,
      markFaceImageUsed: (phoneNumber, objectId, {required failed}) => accounts.store.markFaceImageUsed(phoneNumber, objectId, failed: failed),
    ),
  );

  Future<ChaoxingSignResult> signTarget(
    ChaoxingSignTarget target,
    ChaoxingActivity activity, {
    required ChaoxingActiveInfo info,
    required ChaoxingSignInputs inputs,
    required ChaoxingCaptchaSolver solveCaptcha,
    ChaoxingFreshQrCode? freshQrCode,
    bool force = false,
    bool initialTightened = false,
    void Function()? onTightened,
  }) => signFlow.sign(
    target,
    activity,
    info: info,
    inputs: inputs,
    solveCaptcha: solveCaptcha,
    freshQrCode: freshQrCode,
    force: force,
    initialTightened: initialTightened,
    onTightened: onTightened,
  );

  // 扫到新码时先问一次是否还有效（用当前账号问，与学习通客户端一致）。
  Future<bool> qrCodeExpired(ChaoxingQrCode code, ChaoxingActivity activity) async {
    final client = _requireClient();
    return accounts.run(client, () => chaoxingQrCodeExpired(client, code: code, activeId: activity.activeId));
  }

  // 打开签到页时的检查入口：按这个人的会话查，结果只用来提示与给三选，不产生副作用。
  Future<ChaoxingFailure?> presignCheck(ChaoxingSignTarget target, ChaoxingActivity activity) => signFlow.check(target, activity);

  // 开签前预检人脸照片（选了的→本机存的→学习通里的），缺的现在就报。
  Future<void> prepareFace(ChaoxingSignTarget target, ChaoxingActivity activity, ChaoxingActiveInfo info) =>
      signFlow.prepareFace(target, activity, info);

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
      status: _statusOf(info.endTime),
      userStatus: 0,
      ext: current.ext,
    );
  }

  Future<ChaoxingCaptchaPuzzle> captchaPuzzle(ChaoxingClient client, ChaoxingActivity activity) =>
      accounts.run(client, () => chaoxingCaptchaPuzzle(client, referer: chaoxingPreSignRequestUri(activity: activity, account: client.account!)));

  Future<ChaoxingCaptchaAnswer> solveCaptcha(
    ChaoxingClient client,
    ChaoxingActivity activity,
    ChaoxingCaptchaPuzzle puzzle,
    double position,
  ) => accounts.run(
    client,
    () => chaoxingCaptchaVerify(
      client,
      puzzle: puzzle,
      position: position,
      referer: chaoxingPreSignRequestUri(activity: activity, account: client.account!),
    ),
  );

  Future<Uint8List> captchaImage(ChaoxingClient client, String url) => accounts.run(client, () => chaoxingCaptchaImage(client, url));

  // 签到码与手势码在开签之前用当前账号校验一次。
  Future<bool> checkSignCode(ChaoxingActivity activity, String signCode) async {
    final client = _requireClient();
    return accounts.run(client, () => chaoxingCheckSignCode(client, activeId: activity.activeId, signCode: signCode));
  }

  // 群聊里的签到：先换环信令牌、列群、拉漫游，再按附件拼出活动；类型名认不出来的去详情里问。
  Future<List<ChaoxingActivity>> loadGroupActivities() async {
    final client = _requireClient();
    // 群聊凭证只在用户信息里下发，恢复出来的账号要先补一次（这类密钥不落库）。
    if (client.account!.imPassword.isEmpty) await accounts.refreshAccount(client);
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
      // 类型名认得出的不去问详情，按进行中处理（学习通客户端同样不判迟到）；问过详情的按截止时间判断。
      activities.add(
        ChaoxingActivity(
          activeId: item.activeId,
          courseId: item.courseId,
          classId: item.classId,
          title: item.title.isEmpty ? resolved.label : item.title,
          subtitle: item.courseName.isEmpty ? item.groupName : item.courseName,
          signType: resolved,
          // 发起时刻优先取消息里的（群列表按它排序），其次详情里的。
          startTime: item.startTime ?? info?.startTime ?? DateTime.now().toUtc(),
          endTime: info?.endTime,
          status: _statusOf(info?.endTime),
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

  // 课程页：同名课程合并成一组（一门课多个班），置顶的在前，其余保持课程列表原顺序。
  List<ChaoxingCourseGroup> courseGroups({String query = ''}) {
    final keyword = query.trim().toLowerCase();
    final grouped = <String, List<ChaoxingCourse>>{};
    for (final course in courses) {
      final matched = keyword.isEmpty ||
          course.name.toLowerCase().contains(keyword) ||
          course.teacher.toLowerCase().contains(keyword) ||
          course.schools.toLowerCase().contains(keyword);
      if (matched) grouped.putIfAbsent(course.name, () => []).add(course);
    }
    final groups = [
      for (final entry in grouped.entries)
        ChaoxingCourseGroup(
          name: entry.key,
          courses: entry.value,
          pinned: entry.value.any((course) => pinnedClassIds.contains(course.classId)),
        ),
    ];
    return [...groups.where((group) => group.pinned), ...groups.where((group) => !group.pinned)];
  }

  Future<void> setGroupPinned(ChaoxingCourseGroup group, {required bool pinned}) async {
    final record = current;
    if (record == null) return;
    await accounts.store.setCoursesPinned(record.phoneNumber, group.courses.map((course) => course.classId), pinned: pinned);
    pinnedClassIds = await accounts.store.pinnedCourses(record.phoneNumber);
    _notify();
  }

  // 一组课的全部活动（多个班合并、按活动号去重、新的在前）；部分班级读不到时报个数，全读不到才报错。
  Future<({List<ChaoxingActivity> activities, int failures})> groupActivities(ChaoxingCourseGroup group) async {
    final client = _requireClient();
    var failures = 0;
    final merged = <int, ChaoxingActivity>{};
    final results = await Future.wait(
      group.courses.map((course) async {
        try {
          return await accounts.run(client, () => chaoxingActivities(client, course));
        } catch (failure, stack) {
          campusLog('[Chaoxing] action=course_activities errorType=${failure.runtimeType}\n$stack');
          failures++;
          return null;
        }
      }),
    );
    if (results.every((result) => result == null)) {
      throw const ChaoxingFailure(ChaoxingFailureCode.network, '这门课的签到活动没读到，请稍后重试');
    }
    for (final result in results) {
      for (final activity in result ?? const <ChaoxingActivity>[]) {
        merged.putIfAbsent(activity.activeId, () => activity);
      }
    }
    final activities = merged.values.toList()..sort((first, second) => second.startTime.compareTo(first.startTime));
    return (activities: activities, failures: failures);
  }

  // 导入别人的代签码（取件、解密、登录确认在 ChaoxingDelegateController），导入后刷新账号列表。
  Future<ChaoxingAccountRecord> importCredentialTicket(String raw) async {
    final record = await delegate.importTicket(raw, accountCount: accountList.length);
    _dropClient(record.phoneNumber);
    accountList = await accounts.list();
    _notify();
    return record;
  }

  // 会话彻底失效（对方改了密码等）时重新输密码修复；设备码与学校单位不变。
  Future<void> repairAccount(ChaoxingAccountRecord record, String password) async {
    final client = await clientOf(record);
    await accounts.repair(client, password);
    accountList = await accounts.list();
    current = accountList.where((item) => item.phoneNumber == current?.phoneNumber).firstOrNull ?? current;
    _notify();
  }

  // 切换学校单位：之后课程列表与签到都按这个单位走，切完重新拉一遍。
  Future<void> selectUnit(ChaoxingUnit unit) async {
    final client = _requireClient();
    // 等后台刷新落定再切：刷新若读到切换前的记录，会把刚选的单位连同会话一起写回旧的。
    await _maintenance;
    await accounts.selectUnit(client, unit);
    accountList = await accounts.list();
    current = await accounts.record(client.phoneNumber);
    _notify();
    await refresh();
  }

  // 换模拟的客户端：已开着的会话一起换 UA，再刷新一次。
  Future<void> setProfile(ChaoxingClientProfile value) async {
    await accounts.saveProfile(value);
    for (final client in [?_client, ..._clients.values]) {
      client.http.profile = value;
    }
    _notify();
    await refresh();
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

  Future<void> renameLocation(int id, String label) async {
    await accounts.store.renameLocation(id, label);
    locations = await accounts.store.locations();
    _notify();
  }

  // 离这个位置 withinMeters 米内已有的收藏（签完提示收藏时用它判断「附近已经收藏过了」，对齐参考项目）。
  ChaoxingSavedLocation? nearbyLocation(ChaoxingLocation location, {double withinMeters = 500}) {
    for (final saved in locations) {
      if (chaoxingDistanceMeters(saved.location, location) <= withinMeters) return saved;
    }
    return null;
  }

  Future<void> _open(ChaoxingAccountRecord record) async {
    final generation = ++_generation;
    _client?.close();
    _client = null;
    _dropClient(record.phoneNumber);
    final client = await accounts.clientFor(record.phoneNumber);
    if (client == null) {
      throw const ChaoxingFailure(ChaoxingFailureCode.sessionExpired, '账号已不存在，请重新登录');
    }
    final pinned = await accounts.store.pinnedCourses(record.phoneNumber);
    if (generation != _generation) {
      client.close();
      return;
    }
    _client = client;
    current = record;
    pinnedClassIds = pinned;
    activities = const [];
    pastActivities = const [];
    lessonActivities = const [];
    status = ChaoxingStatus.ready;
    _notify();
    await _loadActivities();
    if (generation != _generation) return;
    // 打开账号就后台刷新一次用户信息（对齐参考项目：顺带验证会话、更新 clientId 与学校单位）。
    // [人工决策-2026-10-07 20:02:42] 不挡活动列表的加载——上游这个接口最慢要 30 秒，阻塞式刷新会让用户对着加载圈等；
    // 会话过期由列表请求经 accounts.run 自动重登一次兜底。等列表加载完再起，别跟推断缓存抢库锁。
    _maintenance = _refreshAccountInBackground(client, generation);
    unawaited(_maintenance);
  }

  // 后台刷新用户信息的链：切换单位等会改账号记录的操作要先等它落定，免得它拿旧记录把新选择覆盖回去。
  Future<void> _maintenance = Future.value();

  Future<void> _refreshAccountInBackground(ChaoxingClient client, int generation) async {
    try {
      await accounts.refreshAccount(client);
      final refreshed = await accounts.record(client.phoneNumber);
      if (refreshed != null && generation == _generation) {
        current = refreshed;
        accountList = await accounts.list();
        _notify();
      }
    } catch (failure, stack) {
      campusLog('[Chaoxing] action=refresh_account errorType=${failure.runtimeType}\n$stack');
    }
  }

  // 拉一遍课程与活动；拉的途中切了账号（代次变了）就整份丢弃，连错误也不报到新账号上。
  Future<void> _loadActivities() async {
    final generation = _generation;
    final client = _requireClient();
    final record = current!;
    loadingActivities = true;
    _notify();
    try {
      final loaded = await _fetchActivities(client, record);
      if (generation != _generation) return;
      courses = loaded.courses;
      activities = [for (final activity in loaded.collected) if (activity.ongoing) activity];
      pastActivities = [for (final activity in loaded.collected) if (!activity.ongoing) activity];
      lessonActivities = loaded.lessons;
    } catch (failure, stack) {
      if (generation == _generation) rethrow;
      campusLog('[Chaoxing] action=activities_stale errorType=${failure.runtimeType}\n$stack');
    } finally {
      if (generation == _generation) {
        loadingActivities = false;
        _notify();
      }
    }
  }

  Future<({List<ChaoxingCourse> courses, List<ChaoxingActivity> collected, List<ChaoxingActivity> lessons})> _fetchActivities(
    ChaoxingClient client,
    ChaoxingAccountRecord record,
  ) async {
    final loadedCourses = await accounts.run(client, () => chaoxingCourses(client));
    var failures = 0;
    // 同一门课的多个班会给回同一场活动，按活动号只留一条（与学习通客户端合并时一样），列表的键才不会重复。
    final merged = <int, ChaoxingActivity>{};
    // 固定并发池：一门课回来就补上下一门，不等整批里最慢的那门。
    final pool = Pool(refreshConcurrency);
    final results = await Future.wait(
      loadedCourses.map(
        (course) => pool.withResource(() async {
          try {
            return await accounts.run(client, () => chaoxingActivities(client, course));
          } catch (failure, stack) {
            campusLog('[Chaoxing] action=activities errorType=${failure.runtimeType}\n$stack');
            failures++;
            return const <ChaoxingActivity>[];
          }
        }),
      ),
    );
    await pool.close();
    for (final result in results) {
      for (final activity in result) {
        merged.putIfAbsent(activity.activeId, () => activity);
      }
    }
    final collected = merged.values.toList();
    if (collected.isEmpty && failures > 0) {
      throw const ChaoxingFailure(ChaoxingFailureCode.network, '签到活动没读到，请稍后重试');
    }
    // [人工决策-2026-10-07 12:32:57] 进行中与往期按活动列表的 status 分（1 为进行中，与学习通客户端一致），
    // 两组分开展示、不混排；往期的活动照样能签（签到页提示可能记为迟到），签到前检查判定已截止/已签到时
    // 还可以强制签到。取代 2026-10-06 23:24:35「往期只读、按截止时间分组」的决定。
    collected.sort((first, second) => second.startTime.compareTo(first.startTime));
    return (
      courses: loadedCourses,
      collected: collected,
      lessons: await _inferFromLessons(client, record, loadedCourses, collected),
    );
  }

  // 课表推断只是提示，读不到学习通课表不影响主列表（记日志即可）。
  Future<List<ChaoxingActivity>> _inferFromLessons(
    ChaoxingClient client,
    ChaoxingAccountRecord record,
    List<ChaoxingCourse> loadedCourses,
    List<ChaoxingActivity> collected,
  ) async {
    try {
      final cached = await accounts.store.lessonCache(record.phoneNumber);
      final now = DateTime.now().toUtc();
      var payload = cached?.payload ?? '';
      var table = cached == null ? null : chaoxingParseLessons(chaoxingJson(payload));
      // 缓存过期，或在期但解析出零节课（视为不可信，对齐参考项目），都重新拉一次，别把空表照用到满 7 天。
      if (table == null || now.difference(cached!.fetchedAt) > ChaoxingStore.lessonCacheLifetime || table.lessons.isEmpty) {
        payload = await accounts.run(client, () => chaoxingFetchLessons(client));
        await accounts.store.putLessonCache(record.phoneNumber, payload);
        table = chaoxingParseLessons(chaoxingJson(payload));
      }
      return await _inferFromTable(client, table, loadedCourses, collected, now);
    } catch (failure, stack) {
      campusLog('[Chaoxing] action=lessons errorType=${failure.runtimeType}\n$stack');
      return const [];
    }
  }

  // 按课表推断：当前节次的课落到班级，班级的活动里挑 20 分钟内刚发起的进行中签到。
  // 课表自带班级号的班可能不在课程列表里（对齐参考项目：这样的班直查一次活动列表补进候选，
  // 而不是只过滤主列表，否则兜底出来的课程对象永远等不到它的活动）。
  Future<List<ChaoxingActivity>> _inferFromTable(
    ChaoxingClient client,
    ChaoxingLessonTable table,
    List<ChaoxingCourse> loadedCourses,
    List<ChaoxingActivity> collected,
    DateTime now,
  ) async {
    final lessonCourses = chaoxingLessonCourses(chaoxingCurrentLessons(table, now), loadedCourses);
    final classIds = {for (final course in lessonCourses) course.classId};
    var candidates = collected;
    final knownClassIds = {for (final course in loadedCourses) course.classId};
    final outside = [for (final course in lessonCourses) if (course.classId > 0 && !knownClassIds.contains(course.classId)) course];
    if (outside.isNotEmpty) {
      final extra = <ChaoxingActivity>[];
      for (final course in outside) {
        try {
          extra.addAll(await accounts.run(client, () => chaoxingActivities(client, course)));
        } catch (failure, stack) {
          // 单个班读不到不影响其余（与主列表同口径）。
          campusLog('[Chaoxing] action=lessons_extra errorType=${failure.runtimeType} classId=${course.classId}\n$stack');
        }
      }
      candidates = [...collected, ...extra];
    }
    return [for (final activity in candidates) if (classIds.contains(activity.classId) && chaoxingFreshActivity(activity, now)) activity];
  }

  // 群聊与签退跳转拼出来的活动没有列表 status，按截止时间补：没截止的当进行中。
  int _statusOf(DateTime? endTime) => endTime == null || DateTime.now().toUtc().isBefore(endTime) ? 1 : 2;

  ChaoxingClient _requireClient() =>
      _client ?? (throw const ChaoxingFailure(ChaoxingFailureCode.sessionExpired, chaoxingSessionExpiredMessage));

  void _dropClient(String phoneNumber) => _clients.remove(phoneNumber)?.close();

  // 业务失败（ChaoxingFailure）只记错误码，学习通改版或会话异常时 logcat 里也有迹可查；其余带完整堆栈。
  void _fail(String action, Object failure, StackTrace stack, String fallback) {
    campusLog(
      failure is ChaoxingFailure
          ? '[Chaoxing] action=$action errorType=${failure.code.name}'
          : '[Chaoxing] action=$action errorType=${failure.runtimeType}\n$stack',
    );
    error = failure is ChaoxingFailure ? failure.message : fallback;
    if (_client == null && accountList.isEmpty) status = ChaoxingStatus.signedOut;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  // 关掉当前账号与其余签到对象的全部会话（退出登录、整页关闭共用）。
  void _closeSessions() {
    _client?.close();
    _client = null;
    for (final client in _clients.values) {
      client.close();
    }
    _clients.clear();
  }

  @override
  void dispose() {
    _disposed = true;
    _closeSessions();
    super.dispose();
  }
}

