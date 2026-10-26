import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'package:superxd/app_session.dart';
import 'package:superxd/domain/account.dart';
import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/domain/share_card.dart';
import 'package:superxd/gateway/account_access.dart';
import 'package:superxd/gateway/kingo_campus_gateway.dart';
import 'package:superxd/local/app_database.dart';
import 'package:superxd/local/display_settings.dart';
import 'package:superxd/main.dart';
import 'package:superxd/social/identity_vault.dart';
import 'package:superxd/social/invite_code.dart';
import 'package:superxd/social/social_service.dart';
import 'package:superxd/social/social_store.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/glass_panel.dart';
import 'package:superxd/theme/third_party_licenses.dart';
import 'package:superxd/toolbox/express/express_client.dart';
import 'package:superxd/toolbox/express/express_http.dart';
import 'package:superxd/toolbox/express/express_models.dart';
import 'package:superxd/toolbox/express/express_service.dart';
import 'package:superxd/toolbox/express/express_vault.dart';
import 'package:superxd/toolbox/toolbox_catalog.dart';
import 'package:superxd/toolbox/toolbox_module.dart';
import 'package:superxd/toolbox/toolbox_runtime.dart';

import '../test/fake_relay.dart';

// README 截图入口（手动，不进 CI）：内存 SQLite 里的合成课表与作息，假登录，不连教务、不读写本机账号库。
// 私信是内存中转上的两台设备（好友「小红」发来一份课表），快递是内存会话加假拼多多，都不联网。
// 课程、教师、教室、快递与取件码均为虚构。运行：flutter run --profile -t tool/readme_demo.dart
Future<void> main() async {
  campusLog = debugPrint;
  WidgetsFlutterBinding.ensureInitialized();
  // 同 main.dart：内容画到导航栏下面，否则截图底部露出一条窗口底色。
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  ensureCampusClock();
  configureCampusIcons();
  registerCampusLicenses();
  final database = await AppDatabase.openMemory();
  final gateway = KingoCampusGateway(database: database);
  const term = TermRef(xn: '2026', xq: '0', label: '2026-2027学年第一学期');
  const previous = TermRef(xn: '2025', xq: '1', label: '2025-2026学年第二学期');
  await database.saveTerms([term, previous], currentXn: term.xn, currentXq: term.xq);
  await database.writeGrades(previous.xn, previous.xq, DateTime.now().toUtc().toIso8601String(), _gradesJson(previous));
  // 开学日取本周往前四周的周一，截图当天落在第 5 周。
  final today = DateTime.now();
  final monday = today.subtract(Duration(days: today.weekday - 1 + 28));
  final start = '${monday.year}-${monday.month.toString().padLeft(2, '0')}-${monday.day.toString().padLeft(2, '0')}';
  await database.setTermStart(term, start);
  await database.writeBells(xn: term.xn, xq: term.xq, fetchedAt: DateTime.now().toUtc().toIso8601String(), empty: false, message: '', periodsJson: _bellsJson);
  await gateway.saveScheduleRevision(term, _courses, '演示课表', expectedRevisionId: null);
  final social = await _demoSocial(term, start);
  final session = AppSession(_DemoAccounts(gateway));
  runApp(SuperXdApp(session: session, display: DisplaySettings.memory(), social: social, toolbox: ToolboxRuntime(catalog: _demoCatalog)));
  await initializeCampusGlass();
  await session.restore();
}

// 私信：自己与好友「小红」两台设备经内存中转互加好友，小红发来同一学期的课表（看好友课表与共同空闲）。
Future<SocialService> _demoSocial(TermRef term, String start) async {
  final relay = FakeRelay();
  final temporary = await getTemporaryDirectory();
  Future<SocialService> device(String name) async {
    final file = File(path.join(temporary.path, 'readme_demo_$name.db'));
    if (file.existsSync()) file.deleteSync();
    final service = SocialService(store: await SocialStore.open(file.path), vault: MemoryIdentityVault(), transport: relay.transport());
    await service.initialize();
    await service.enable(name);
    return service;
  }
  final me = await device('林同学'), friend = await device('小红');
  await friend.redeem(InviteCode.decode((await me.createInvite()).encode())!);
  await me.refresh();
  await friend.refresh();
  await friend.send(friend.friends.first.deviceId, ScheduleShare(term: term, courses: _friendCourses, bells: _bells(), termStartDate: start));
  await me.refresh();
  return me;
}

// 百宝箱用正式注册表，只把快递换成内存会话加假拼多多（已登录、驿站有件），其余工具照常。
List<ToolboxModule> _demoCatalog(ToolboxRuntime runtime) => [
  for (final module in toolboxCatalog(runtime))
    module.id == ExpressService.serviceId
        ? ToolboxModule(id: module.id, name: module.name, icon: module.icon, builder: module.builder, clearedData: module.clearedData, shortcuts: module.shortcuts, openService: (_) async => _demoExpress())
        : module,
];

Future<ExpressService> _demoExpress() async {
  final vault = MemoryExpressVault();
  await vault.save(const PddSession(accessToken: 'demo', cookie: 'PDDAccessToken=demo', userId: '1000000', nickname: '林同学', pickupMobile: '138****0000', pickupMore: true));
  await vault.saveStationLinked(true);
  return ExpressService(vault: vault, clientFactory: (session) => ExpressClient(session: session, http: ExpressHttp(client: _fakePdd())));
}

// 合成拼多多：一个驿站三件待取件，物流的 package_info 写寄到的手机尾号（两件 0000、一件 1111），近一周取走一件；身份码 10 分钟有效。
http.Client _fakePdd() => MockClient((request) async {
  final route = request.url.path;
  final Object body;
  if (route.endsWith('/shipping/track')) {
    final number = request.url.queryParameters['tracking_number'] ?? '';
    body = {'error_code': null, 'shipping': {'shipping_name': '合成快递', 'tracking_number': number, 'package_info': number == 'SX0000000003' ? '尾号1111 的快递' : '尾号0000 的快递', 'traces': [{'info': '快件已到达合成驿站一号，请凭取件码取件', 'time': '2026-10-26 09:12:00'}]}};
  } else if (route.endsWith('/station/package')) {
    body = {
      'success': true,
      'error_code': '0',
      'result': {
        'count': 3,
        'combine_list': [
          {
            'company_name': '合成驿站一号',
            'address': '示例路 1 号',
            'combine_track_list': [
              for (final (index, code) in ['3-2-1001', '3-2-1002', '5-1-2003'].indexed)
                {'pick_code': '取件码 $code', 'shipping_name': '合成快递', 'tracking_number': 'SX000000000${index + 1}', 'shipping_id': 1},
            ],
          },
        ],
        'package_out_list': [
          {'address': '示例路 1 号', 'operate_time': '10-24 18:05', 'shipping_name': '合成快递', 'tracking_number': 'SX0000000009', 'jump_url': '/track?tracking_number=SX0000000009&shipping_id=1&source_type=3'},
        ],
      },
    };
  } else {
    body = {'success': true, 'error_code': '0', 'result': {'identification_code': 'dd20261026000000001234', 'expire_mills': 600000}};
  }
  return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json;charset=UTF-8'});
});

const _bellsJson = '[{"period":1,"start":"08:00","end":"08:45"},{"period":2,"start":"08:55","end":"09:40"},{"period":3,"start":"10:00","end":"10:45"},{"period":4,"start":"10:55","end":"11:40"},{"period":5,"start":"14:00","end":"14:45"},{"period":6,"start":"14:55","end":"15:40"},{"period":7,"start":"16:00","end":"16:45"},{"period":8,"start":"16:55","end":"17:40"},{"period":9,"start":"19:00","end":"19:45"},{"period":10,"start":"19:55","end":"20:40"}]';

final _allWeeks = List.generate(16, (index) => index + 1);
CourseRecord _course(String code, String name, String teacher, double credit, List<(int, int, int, String)> meetings) => CourseRecord(
  courseCode: code, courseName: name, sectionId: '$code-01', credit: credit, teacherName: teacher,
  meetings: [for (final (weekday, start, end, place) in meetings) CourseMeeting(weekday: weekday, periodStart: start, periodEnd: end, place: place, weeks: _allWeeks)],
);

final _courses = [
  _course('D101', '高等数学（上）', '林老师', 5, [(1, 1, 2, '明德楼 A201'), (3, 3, 4, '明德楼 A201')]),
  _course('D102', '大学英语', '周老师', 3, [(1, 5, 6, '外语楼 305'), (4, 1, 2, '外语楼 305')]),
  _course('D103', '程序设计基础', '陈老师', 4, [(2, 1, 2, '信息楼 B402'), (5, 3, 4, '实验中心 210')]),
  _course('D104', '线性代数', '赵老师', 3, [(2, 5, 6, '明德楼 C108')]),
  _course('D105', '大学物理', '孙老师', 4, [(3, 1, 2, '格物楼 101'), (5, 1, 2, '格物楼 101')]),
  _course('D106', '思想道德与法治', '吴老师', 3, [(4, 5, 6, '综合楼 402')]),
  _course('D107', '体育', '郑老师', 1, [(1, 3, 4, '东区体育馆')]),
  _course('D108', '创新创业基础', '冯老师', 2, [(3, 9, 10, '综合楼 210')]),
];

// 好友小红的合成课表：和自己有一门同班的大学英语，其余错开，共同空闲里能看出两人都没课的时段。
final _friendCourses = [
  _course('E201', '数据结构', '何老师', 4, [(1, 1, 2, '信息楼 B201'), (3, 5, 6, '信息楼 B201')]),
  _course('E202', '概率论', '许老师', 3, [(2, 3, 4, '明德楼 A305')]),
  _course('D102', '大学英语', '周老师', 3, [(1, 5, 6, '外语楼 305'), (4, 1, 2, '外语楼 305')]),
  _course('E203', '电路分析', '马老师', 4, [(4, 3, 4, '电气楼 110'), (5, 5, 6, '电气楼 110')]),
];

List<BellPeriod> _bells() => [
  for (final period in (jsonDecode(_bellsJson) as List).cast<Map<String, Object?>>())
    BellPeriod(period: period['period']! as int, dayPart: '', dayPartCode: '', start: period['start']! as String, end: period['end']! as String),
];

// 上一学期的合成成绩（成绩页截图用）：课程沿用演示课表，分数虚构，绩点按分数线性折算。
String _gradesJson(TermRef term) {
  const scores = [92, 86, 95, 78, 84, 90, 88, 81];
  final rows = [for (final (index, course) in _courses.indexed) (course: course, score: scores[index])];
  return jsonEncode({
    'empty': false,
    'message': '',
    'term': {'xn': term.xn, 'xq': term.xq, 'label': term.label},
    'student': {'loginId': '20260000001', 'name': '林同学', 'college': '示例学院', 'major': '示例专业', 'level': '本科', 'className': '示例计算机班'},
    'summary': {'earnedCredit': 25, 'gpa': 3.75, 'averageScore': 86.75, 'weightedAverage': 87.52},
    'summaryScope': 'term',
    'effective': [
      for (final row in rows)
        {'courseCode': row.course.courseCode, 'courseName': row.course.courseName, 'credit': row.course.credit, 'score': row.score, 'earnedCredit': row.course.credit, 'gradePoint': (row.score - 50) / 10},
    ],
    'original': [
      for (final row in rows)
        {'courseCode': row.course.courseCode, 'courseName': row.course.courseName, 'credit': row.course.credit, 'usualScore': row.score, 'midtermScore': null, 'finalScore': row.score, 'skillScore': null, 'totalScore': row.score},
    ],
  });
}

// 假登录：账号固定为一个虚构学生，教务数据全部走内存库里的合成数据。
class _DemoAccounts extends AccountAccess {
  _DemoAccounts(this.inner);
  final CampusGateway inner;
  final SessionView _student = const SessionView(loginId: '20260000001', name: '林同学', className: '示例计算机班');

  @override
  int get generation => 1;
  @override
  SessionView? get activeSession => _student;
  @override
  AccountIdentity? get activeIdentity => AccountIdentity(source: 'https://school.example', loginId: _student.loginId);
  @override
  Future<GatewayResult<SessionView>> restoreSession() async => GatewayResult(ok: true, source: 'local', fetchedAt: DateTime.now().toUtc().toIso8601String(), data: _student);
  @override
  Future<GatewayResult<LoginView>> login(String account, String password) async => GatewayResult(ok: true, source: 'local', fetchedAt: DateTime.now().toUtc().toIso8601String(), data: LoginView(session: _student));
  @override
  Future<void> cancelLogin() async {}
  @override
  Future<void> logout() async {}
  @override
  Future<LegacyImportState> legacyImportState() async => const LegacyImportState(available: false, deferred: false);
  @override
  Future<void> deferLegacyImport() async {}
  @override
  Future<GatewayResult<LegacyImportReport>> importLegacy() => throw UnsupportedError('演示模式没有旧数据');
  @override
  Future<void> close() async {}

  @override
  Future<GatewayResult<LoginView>> submitLoginCaptcha(String code) => inner.submitLoginCaptcha(code);
  @override
  Future<GatewayResult<CaptchaView>> refreshLoginCaptcha() => inner.refreshLoginCaptcha();
  @override
  Future<GatewayResult<List<TermRef>>> listTerms() => inner.listTerms();
  @override
  Future<GatewayResult<List<TermRef>>> syncTerms() => inner.listTerms();
  @override
  Future<GatewayResult<ScheduleView>> syncSchedule(TermRef term) => inner.readSchedule(ScheduleScope.term(term));
  @override
  Future<GatewayResult<ScheduleView>> readSchedule(ScheduleScope scope) => inner.readSchedule(scope);
  @override
  Future<GatewayResult<GradesView>> syncGrades(TermRef term) => inner.readGrades(term);
  @override
  Future<GatewayResult<GradesView>> readGrades(TermRef term) => inner.readGrades(term);
  @override
  Future<GatewayResult<List<GradeTermOverview>>> readGradeYear(String year) => inner.readGradeYear(year);
  @override
  Future<GatewayResult<BellsView>> syncBells(TermRef term) => inner.readBells(term);
  @override
  Future<GatewayResult<BellsView>> readBells(TermRef term) => inner.readBells(term);
  @override
  Future<GatewayResult<TermRef?>> readBellsSource(TermRef term) => inner.readBellsSource(term);
  @override
  Future<GatewayResult<TermRef>> useBellsSource(TermRef target, TermRef source) => inner.useBellsSource(target, source);
  @override
  Future<GatewayResult<TermRef>> setTermStart(TermRef term, String date) => inner.setTermStart(term, date);
  @override
  Future<GatewayResult<RevisionView>> saveScheduleRevision(TermRef term, List<CourseRecord> courses, String summary, {required String? expectedRevisionId}) => inner.saveScheduleRevision(term, courses, summary, expectedRevisionId: expectedRevisionId);
  @override
  Future<GatewayResult<SyncPlan>> planScheduleSync(TermRef term, List<CourseRecord> courses) => inner.planScheduleSync(term, courses);
  @override
  Future<GatewayResult<RevisionView>> commitScheduleSync(TermRef term, List<CourseRecord> courses, {required bool confirm, String? expectedRevisionId}) => inner.commitScheduleSync(term, courses, confirm: confirm, expectedRevisionId: expectedRevisionId);
  @override
  Future<GatewayResult<List<RevisionView>>> listScheduleRevisions(TermRef term, {int? beforeSequence, int limit = 20}) => inner.listScheduleRevisions(term, beforeSequence: beforeSequence, limit: limit);
  @override
  Future<GatewayResult<ScheduleRevision>> readScheduleRevision(TermRef term, String id) => inner.readScheduleRevision(term, id);
  @override
  Future<GatewayResult<RevisionView>> restoreScheduleRevision(TermRef term, String id, {required String? expectedRevisionId}) => inner.restoreScheduleRevision(term, id, expectedRevisionId: expectedRevisionId);
  @override
  Future<GatewayResult<ReminderSetting>> readReminderSetting(TermRef term) => inner.readReminderSetting(term);
  @override
  Future<GatewayResult<ReminderSetting>> saveReminderSetting(TermRef term, ReminderSetting setting) => inner.saveReminderSetting(term, setting);
}
