import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pool/pool.dart';
import 'package:synchronized/synchronized.dart';

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
  ChaoxingController({
    required this.accounts,
    this.hub,
    this.filePublisher,
    this.temporaryDirectory = getTemporaryDirectory,
    this.lessonPollInterval = const Duration(seconds: 5),
    this.lessonPollWindow = const Duration(minutes: 2),
  });
  final ChaoxingAccounts accounts;

  // 代签凭据包的中转；没配中转时为 null，出示与扫码导入都不显示。
  final ChaoxingPackHub? hub;
  // 公共下载目录的文件导出（人脸照片保存到本机用）；为空时保存入口不可用（测试环境）。
  final ToolboxFilePublisher Function()? filePublisher;
  // 人脸照片导出前落盘的临时目录（见 ChaoxingFaceController）。
  final Future<Directory> Function() temporaryDirectory;

  // 一次刷新最多并发三个课程请求，课程多时也不至于把刷新拖太久。
  static const refreshConcurrency = 3;

  // 课表推断轮询（参考项目 1.19.2）：每次读完列表后，还没推断到签到就每隔 lessonPollInterval 重查当前这节课的签到，
  // 最多 lessonPollWindow，查到就停；老师上课后才发起的签到不用手动刷新也会出现在「可能正在签到」里。
  final Duration lessonPollInterval;
  final Duration lessonPollWindow;
  Timer? _lessonPoll;
  ChaoxingLessonTable? _lessonTable;

  ChaoxingStatus status = ChaoxingStatus.loading;
  List<ChaoxingAccountRecord> accountList = const [];
  ChaoxingAccountRecord? current;

  // 账号标签，以及每个账号挂的标签号。
  List<ChaoxingAccountTag> tags = const [];
  Map<String, Set<int>> accountTags = const {};
  List<ChaoxingCourse> courses = const [];

  // 进行中的签到（活动列表 status 为 1 的）。
  List<ChaoxingActivity> activities = const [];

  // 已结束的活动，给「往期签到」入口用；照样能签，签到页会提示可能记迟到。
  List<ChaoxingActivity> pastActivities = const [];

  // 按学习通课表推断的「可能正在签到」：当前节次的课里刚发起（20 分钟内）的进行中签到。
  List<ChaoxingActivity> lessonActivities = const [];
  Set<int> pinnedClassIds = const {};
  List<ChaoxingSavedLocation> locations = const [];
  // 签完问收藏时选了「这附近不再问」的地点。
  List<ChaoxingLocation> quietPlaces = const [];
  String? error;
  // 登录、切换账号进行中。刷新列表不算在内：刷新时页面上别的按钮照常可点，也照常能切账号。
  bool busy = false;

  // 正在拉课程与活动：列表为空时显示加载中，而不是「没有可签到的活动」。
  bool loadingActivities = false;
  // 当前账号与设置下的列表读到过。刚打开、刚改了学校单位或客户端、一直没读成时为否，这时列表为空不等于没有活动。
  bool activitiesLoaded = false;
  ChaoxingClient? _client;
  final _clients = <String, ChaoxingClient>{};
  bool _disposed = false;

  // 账号代次：每打开一个账号加一。异步结果回来时代次已变（期间切了账号），就丢弃不写，
  // 免得旧账号的列表或错误落到新账号的界面上（同今天页的 _readGeneration）。
  int _generation = 0;

  ChaoxingAccount? get account => _client?.account;
  ChaoxingClientProfile get profile => accounts.profile;

  // 主账号：账号列表把它排在第一（见 ChaoxingAccounts.list），排第一的是自己登录的账号就是它；没有自己登录的账号时为空。
  String? get mainPhoneNumber {
    final first = accountList.firstOrNull;
    return first == null || first.isOtherUser ? null : first.phoneNumber;
  }

  // 账号说明里的归属：主账号写「主账号」，代签账号写「代签账号」，其余不写（只标例外）。
  String? ownerLabelOf(ChaoxingAccountRecord record) => record.phoneNumber == mainPhoneNumber ? '主账号' : record.ownerLabel;

  // 签到对象：当前账号排第一并默认勾上，其余账号默认不勾；登录已失效的一打开就给「重新登录」。
  List<ChaoxingSignTarget> signTargets() => [
    if (current != null) ChaoxingSignTarget(current!, selected: true)..needsRepair = current!.sessionExpired,
    for (final record in accountList)
      if (record.phoneNumber != current?.phoneNumber) ChaoxingSignTarget(record)..needsRepair = record.sessionExpired,
  ];

  List<ChaoxingAccountTag> tagsOf(ChaoxingAccountRecord record) {
    final ids = accountTags[record.phoneNumber] ?? const <int>{};
    return [for (final tag in tags) if (ids.contains(tag.id)) tag];
  }

  bool hasTag(ChaoxingAccountRecord record, ChaoxingAccountTag tag) => accountTags[record.phoneNumber]?.contains(tag.id) ?? false;

  // 账号列表与标签重读一遍：签到弹层关掉后（期间可能有账号被标了登录已失效）、标签改动后。
  Future<void> reloadAccounts() async {
    accountList = await accounts.list();
    await _loadTags();
    _notify();
  }

  Future<void> _loadTags() async {
    tags = await accounts.store.tags();
    accountTags = await accounts.store.accountTags();
  }

  Future<void> saveTag({int? id, required String name, required int colorIndex}) async {
    await accounts.saveTag(id: id, name: name, colorIndex: colorIndex);
    await _loadTags();
    _notify();
  }

  Future<void> removeTag(ChaoxingAccountTag tag) async {
    await accounts.store.removeTag(tag.id);
    await _loadTags();
    _notify();
  }

  Future<void> setAccountTags(ChaoxingAccountRecord record, Set<int> tagIds) async {
    await accounts.store.setAccountTags(record.phoneNumber, tagIds);
    await _loadTags();
    _notify();
  }

  Future<void> initialize() async {
    status = ChaoxingStatus.loading;
    error = null;
    _notify();
    try {
      await accounts.loadProfile();
      accountList = await accounts.list();
      await _loadTags();
      locations = await accounts.store.locations();
      quietPlaces = await accounts.store.quietPlaces();
      if (accountList.isEmpty) {
        status = ChaoxingStatus.signedOut;
        _notify();
        return;
      }
      // 每次打开都进主账号（排第一），不记上次切到哪个，免得误用别人的账号签到。
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
    _lessonPoll?.cancel();
    _closeSessions();
    current = null;
    activities = const [];
    pastActivities = const [];
    lessonActivities = const [];
    courses = const [];
    activitiesLoaded = false;
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

  // 设为主账号：之后打开工具都进它，账号列表里它排第一。
  Future<void> setMainAccount(ChaoxingAccountRecord record) async {
    await accounts.setMainAccount(record);
    accountList = await accounts.list();
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
        _lessonPoll?.cancel();
        _client?.close();
        _client = null;
        current = null;
        activities = const [];
        pastActivities = const [];
        lessonActivities = const [];
        courses = const [];
        activitiesLoaded = false;
      }
      accountList = await accounts.list();
      await _loadTags();
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

  // 刷新列表：已有一轮在拉就等那一轮（下拉、签完后的刷新不重复发请求）；登录、切换账号进行中时不刷新。
  Future<void> refresh() async {
    if (busy || _client == null) return;
    error = null;
    _notify();
    try {
      await (_listLoad ?? _loadActivities());
    } catch (failure, stack) {
      _fail('refresh', failure, stack, '刷新未完成，请检查网络后重试');
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
  late final faces = ChaoxingFaceController(
    accounts: accounts,
    clientOf: clientOf,
    currentClient: _requireClient,
    filePublisher: filePublisher,
    temporaryDirectory: temporaryDirectory,
  );
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
      startTime: info.startTime,
      endTime: info.endTime,
      status: _statusOf(info.endTime),
      userStatus: 0,
      ext: current.ext,
    );
  }

  // 首页扫课堂签到二维码（参考项目 1.19.2）：码里只有活动号，按详情组出活动，课程列表里找不到这门课也能签。
  // 班级与课程号取详情里的，详情没给课程号时按班级到课程列表里找；课程名同样从课程列表找，
  // 找不到时按班级号查班级名（同参考项目），也查不到才用「课堂签到」。
  Future<ChaoxingActivity> scannedActivity(ChaoxingQrCode code) async {
    final activeId = code.activeId;
    if (activeId == null) {
      throw const ChaoxingFailure(ChaoxingFailureCode.invalidInput, '这个二维码里没有签到活动');
    }
    final client = _requireClient();
    final info = await accounts.run(client, () => chaoxingActiveInfo(client, activeId));
    final signType = info.signType;
    if (signType == null) {
      throw const ChaoxingFailure(ChaoxingFailureCode.unsupported, chaoxingUnsupportedTypeMessage);
    }
    final course = courses.where((course) => course.classId == info.classId).firstOrNull;
    campusLog('[Chaoxing] action=scan_activity type=${signType.name} knownCourse=${course != null}');
    return ChaoxingActivity(
      activeId: activeId,
      courseId: info.courseId != 0 ? info.courseId : course?.courseId ?? 0,
      classId: info.classId,
      title: info.title.isEmpty ? signType.label : info.title,
      subtitle: course?.name ?? await _className(client, info.classId) ?? '课堂签到',
      signType: signType,
      startTime: info.startTime,
      endTime: info.endTime,
      status: _statusOf(info.endTime),
      userStatus: 0,
      ext: '',
    );
  }

  // 班级名只是标题，查不到不挡签到：记日志后返回空。
  Future<String?> _className(ChaoxingClient client, int classId) async {
    if (classId == 0) return null;
    try {
      return await accounts.run(client, () => chaoxingClassName(client, classId));
    } catch (failure, stack) {
      campusLog('[Chaoxing] action=class_name errorType=${failure.runtimeType}\n$stack');
      return null;
    }
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

  // 群聊列表：换环信令牌、列出加入的群（一次请求，最多 chaoxingImGroupLimit 个），连同这个账号置顶的群；不拉消息。
  Future<({List<ChaoxingImGroup> chats, Set<String> pinned})> loadChats() async {
    final client = await _imClient();
    final chats = await accounts.run(client, () async => chaoxingImGroups(client, await chaoxingImConfig(client)));
    return (chats: chats, pinned: await accounts.store.pinnedChats(client.phoneNumber));
  }

  // 置顶或取消置顶一项（同名的几个群一起），返回这个账号现在置顶的群。
  Future<Set<String>> setChatPinned(ChaoxingChatGroup group, {required bool pinned}) async {
    final phoneNumber = _requireClient().phoneNumber;
    await accounts.store.setChatsPinned(phoneNumber, group.groups.map((chat) => chat.id), pinned: pinned);
    return accounts.store.pinnedChats(phoneNumber);
  }

  // 群聊凭证只在用户信息里下发，恢复出来的账号要先补一次（这类密钥不落库）。
  Future<ChaoxingClient> _imClient() async {
    final client = _requireClient();
    if (client.account!.imPassword.isEmpty) await accounts.refreshAccount(client);
    return client;
  }

  // 一项（同名的几个群）里的签到：只拉这几个群的漫游，按附件拼出活动；类型名认不出来的去详情里问。
  // failures 是详情没问到、被跳过的签到场数。
  Future<({List<ChaoxingActivity> activities, int failures})> chatActivities(ChaoxingChatGroup group) async {
    final client = await _imClient();
    final found = await accounts.run(client, () async => chaoxingImActivitiesOf(client, await chaoxingImConfig(client), group.groups));
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
          // 发起时刻优先取消息里的，其次详情里的；都没有就是未知。
          startTime: item.startTime ?? info?.startTime,
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
    // 消息里没时间、详情里补上了的要按补上的时间重排。
    return (activities: activities..sort(chaoxingNewestFirst), failures: failures);
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
    final activities = merged.values.toList()..sort(chaoxingNewestFirst);
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

  // 学校单位与客户端的改动排队落库：连着点了几项时按点的顺序一个个存，最后点的那项生效。
  final _settingsLock = Lock();

  // 切换学校单位：之后课程列表与签到都按这个单位走。存好就返回（设置弹层不等列表），列表随后清空重拉；
  // 重拉的结果与错误由首页显示（_reloadActivities 自己接住错误）。
  Future<void> selectUnit(ChaoxingUnit unit) async {
    final client = _requireClient();
    await _settingsLock.synchronized(() async {
      // 等后台刷新落定再切：刷新若读到切换前的记录，会把刚选的单位连同会话一起写回旧的。
      await _maintenance;
      await accounts.selectUnit(client, unit);
      accountList = await accounts.list();
      current = await accounts.record(client.phoneNumber);
      _notify();
    });
    unawaited(_reloadActivities());
  }

  // 换模拟的客户端：已开着的会话一起换 UA；存好就返回，列表随后清空重拉（同切换学校单位）。
  Future<void> setProfile(ChaoxingClientProfile value) async {
    await _settingsLock.synchronized(() async {
      await accounts.saveProfile(value);
      for (final client in [?_client, ..._clients.values]) {
        client.http.profile = value;
      }
    });
    _notify();
    unawaited(_reloadActivities());
  }

  // [人工决策-2026-10-17 16:16:34] 改了学校单位或模拟的客户端，课程列表按新设置下发，旧列表不再作数：先清空，在列表位置显示加载，
  // 再重新拉一遍（同切换账号）。用户从选项中选定，未选「保留旧列表静默刷新」「顶部出下拉刷新那个指示」；签完后的刷新照旧保留列表、静默进行。
  // 改设置之前开始的那一轮读回来就丢弃（见 _loadActivities）。
  Future<void> _reloadActivities() async {
    if (busy || _client == null) return;
    _lessonPoll?.cancel();
    courses = const [];
    activities = const [];
    pastActivities = const [];
    lessonActivities = const [];
    activitiesLoaded = false;
    error = null;
    try {
      await _loadActivities();
    } catch (failure, stack) {
      _fail('reload', failure, stack, '签到活动没读到，请稍后重试');
    }
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

  // 位置签到默认选中的位置：这门课上次签到用的，没有就用上次签到（任何课）用的；都没有为空，由弹层改用当前位置。
  // 只存本机、不算收藏，清除数据随库删。
  Future<ChaoxingLocation?> signedLocation(ChaoxingActivity activity) => accounts.store.signedLocation(activity.classId);

  Future<void> rememberSignedLocation(ChaoxingActivity activity, ChaoxingLocation location) =>
      accounts.store.putSignedLocation(activity.classId, location);

  // 离这个位置 withinMeters 米内已有的收藏（签完提示收藏时用它判断「附近已经收藏过了」，对齐参考项目）。
  ChaoxingSavedLocation? nearbyLocation(ChaoxingLocation location, {double withinMeters = 500}) {
    for (final saved in locations) {
      if (chaoxingDistanceMeters(saved.location, location) <= withinMeters) return saved;
    }
    return null;
  }

  // 签完要不要问收藏（同参考项目）：500 米内已有收藏，或用户在附近选过「这附近不再问」，就不问。
  bool shouldOfferSave(ChaoxingLocation location) =>
      nearbyLocation(location) == null && !quietPlaces.any((place) => chaoxingDistanceMeters(place, location) <= 500);

  Future<void> quietNearby(ChaoxingLocation location) async {
    await accounts.store.putQuietPlace(location);
    quietPlaces = await accounts.store.quietPlaces();
    _notify();
  }

  Future<void> _open(ChaoxingAccountRecord record) async {
    final generation = ++_generation;
    _lessonPoll?.cancel();
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
    activitiesLoaded = false;
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

  // 正在进行的那一轮列表读取，刷新时有就等它。每起一轮 _listGeneration 加一，只有最新的一轮写界面。
  Future<void>? _listLoad;
  int _listGeneration = 0;

  Future<void> _loadActivities() {
    final load = _loadActivitiesOnce();
    _listLoad = load;
    return load.whenComplete(() {
      if (identical(_listLoad, load)) _listLoad = null;
    });
  }

  // 拉一遍课程与活动；拉的途中切了账号（代次变了）或又起了一轮（改了单位或客户端），就整份丢弃，连错误也不报。
  Future<void> _loadActivitiesOnce() async {
    final generation = _generation;
    final listGeneration = ++_listGeneration;
    bool latest() => generation == _generation && listGeneration == _listGeneration;
    final client = _requireClient();
    final record = current!;
    loadingActivities = true;
    _notify();
    try {
      final loaded = await _fetchActivities(client, record);
      if (!latest()) return;
      courses = loaded.courses;
      activities = [for (final activity in loaded.collected) if (activity.ongoing) activity];
      pastActivities = [for (final activity in loaded.collected) if (!activity.ongoing) activity];
      lessonActivities = loaded.lessons.activities;
      _lessonTable = loaded.lessons.table;
      activitiesLoaded = true;
      _startLessonPoll(client, latest);
    } catch (failure, stack) {
      if (latest()) rethrow;
      campusLog('[Chaoxing] action=activities_stale errorType=${failure.runtimeType}\n$stack');
    } finally {
      if (latest()) {
        loadingActivities = false;
        _notify();
      }
    }
  }

  Future<({List<ChaoxingCourse> courses, List<ChaoxingActivity> collected, _LessonInference lessons})> _fetchActivities(
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
    collected.sort(chaoxingNewestFirst);
    return (
      courses: loadedCourses,
      collected: collected,
      lessons: await _inferFromLessons(client, record, loadedCourses, collected),
    );
  }

  // 课表推断只是提示，读不到学习通课表不影响主列表（记日志即可）。课表一并交回，给之后的轮询用。
  Future<_LessonInference> _inferFromLessons(
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
      return (activities: await _inferFromTable(client, table, loadedCourses, collected, now), table: table);
    } catch (failure, stack) {
      campusLog('[Chaoxing] action=lessons errorType=${failure.runtimeType}\n$stack');
      return (activities: const <ChaoxingActivity>[], table: null);
    }
  }

  // 读完列表还没推断到签到、而且现在正有课时开始轮询；换账号、退出、关页面、下课、查到了或列表又重拉了就停（latest 为否）。
  void _startLessonPoll(ChaoxingClient client, bool Function() latest) {
    _lessonPoll?.cancel();
    final deadline = DateTime.now().add(lessonPollWindow);
    void schedule() {
      if (_disposed || !latest() || lessonActivities.isNotEmpty || !DateTime.now().isBefore(deadline)) return;
      final table = _lessonTable;
      if (table == null || chaoxingCurrentLessons(table, DateTime.now().toUtc()).isEmpty) return;
      _lessonPoll = Timer(lessonPollInterval, () {
        _pollLessons(client).then((found) {
          if (_disposed || !latest()) return;
          if (found.isEmpty) {
            schedule();
            return;
          }
          campusLog('[Chaoxing] action=lessons_poll result=found count=${found.length}');
          lessonActivities = found;
          _notify();
        }).catchError((Object error, StackTrace stack) {
          campusLog('[Chaoxing] action=lessons_poll errorType=${error.runtimeType}\n$stack');
        });
      });
    }

    schedule();
  }

  // 一轮轮询：只查当前这节课对上的那几个班（与刷新时的推断同口径），某个班读不到只记日志，下一轮再试。
  Future<List<ChaoxingActivity>> _pollLessons(ChaoxingClient client) async {
    final table = _lessonTable;
    if (table == null) return const [];
    final now = DateTime.now().toUtc();
    final lessonCourses = chaoxingLessonCourses(chaoxingCurrentLessons(table, now), courses);
    final found = <int, ChaoxingActivity>{};
    for (final course in lessonCourses) {
      try {
        for (final activity in await accounts.run(client, () => chaoxingActivities(client, course))) {
          if (chaoxingFreshActivity(activity, now)) found.putIfAbsent(activity.activeId, () => activity);
        }
      } catch (failure, stack) {
        campusLog('[Chaoxing] action=lessons_poll errorType=${failure.runtimeType} classId=${course.classId}\n$stack');
      }
    }
    return found.values.toList()..sort(chaoxingNewestFirst);
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
    _lessonPoll?.cancel();
    _closeSessions();
    super.dispose();
  }
}

// 课表推断的结果与这次用的课表（轮询接着用它看当前是哪节课）；课表读不到时为空。
typedef _LessonInference = ({List<ChaoxingActivity> activities, ChaoxingLessonTable? table});

