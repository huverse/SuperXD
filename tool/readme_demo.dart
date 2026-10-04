import 'package:flutter/material.dart';

import 'package:superxd/app_session.dart';
import 'package:superxd/domain/account.dart';
import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/gateway/account_access.dart';
import 'package:superxd/gateway/kingo_campus_gateway.dart';
import 'package:superxd/local/app_database.dart';
import 'package:superxd/local/display_settings.dart';
import 'package:superxd/main.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/glass_panel.dart';
import 'package:superxd/theme/third_party_licenses.dart';

// README 截图入口（手动，不进 CI）：内存 SQLite 里的合成课表与作息，假登录，不连教务、不读写本机账号库。
// 课程、教师与教室均为虚构。运行：flutter run -t tool/readme_demo.dart
Future<void> main() async {
  campusLog = debugPrint;
  WidgetsFlutterBinding.ensureInitialized();
  ensureCampusClock();
  configureCampusIcons();
  registerCampusLicenses();
  final database = await AppDatabase.openMemory();
  final gateway = KingoCampusGateway(database: database);
  const term = TermRef(xn: '2026', xq: '0', label: '2026-2027学年第一学期');
  await database.saveTerms([term], currentXn: term.xn, currentXq: term.xq);
  // 开学日取本周往前四周的周一，截图当天落在第 5 周。
  final today = DateTime.now();
  final monday = today.subtract(Duration(days: today.weekday - 1 + 28));
  await database.setTermStart(term, '${monday.year}-${monday.month.toString().padLeft(2, '0')}-${monday.day.toString().padLeft(2, '0')}');
  await database.writeBells(xn: term.xn, xq: term.xq, fetchedAt: DateTime.now().toUtc().toIso8601String(), empty: false, message: '', periodsJson: _bellsJson);
  await gateway.saveScheduleRevision(term, _courses, '演示课表', expectedRevisionId: null);
  final session = AppSession(_DemoAccounts(gateway));
  runApp(SuperXdApp(session: session, display: DisplaySettings.memory()));
  await initializeCampusGlass();
  await session.restore();
}

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
