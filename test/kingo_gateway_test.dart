import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:superxd/edu/kingo_client.dart';
import 'package:superxd/edu/parse_bells.dart';
import 'package:superxd/edu/parse_grades.dart';
import 'package:superxd/edu/parse_schedule.dart';
import 'package:superxd/gateway/kingo_campus_gateway.dart';
import 'package:superxd/local/app_database.dart';
import 'package:superxd/domain/schedule_store.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('登录验证码留在同一次会话，成功后写入 SQLite，密码不落库', () async {
    final database = await AppDatabase.openMemory();
    final fake = _FakeKingo();
    final gateway = KingoCampusGateway(database: database, client: fake, now: () => DateTime.utc(2026, 9, 24));
    final first = await gateway.login('20260000001', 'secret-value');
    expect(first.ok, isTrue);
    expect(first.needsInput, 'captcha');
    final again = await gateway.submitLoginCaptcha('bad');
    expect(again.needsInput, 'captcha');
    expect(again.data?.captcha?.hint, '验证码不正确，请重新输入');
    final done = await gateway.submitLoginCaptcha('ok');
    expect(done.ok, isTrue);
    expect(done.needsInput, isNull);
    expect(done.data?.session?.loginId, '20260000001');
    final saved = await database.readSession();
    expect(saved?.cookieJson.contains('secret-value'), isFalse);
    expect(saved?.cookieJson.contains('U1'), isTrue);
    final restored = KingoCampusGateway(database: database, client: _FakeKingo(), now: () => DateTime.utc(2026, 9, 24));
    final session = await restored.restoreSession();
    expect(session.ok, isTrue);
    expect(session.data?.loginId, '20260000001');
  });

  test('课表同步和自定义版本写入 SQLite，重新打开仍能回退', () async {
    final database = await AppDatabase.openMemory();
    final gateway = KingoCampusGateway(database: database, client: _FakeKingo(), now: () => DateTime.utc(2026, 9, 24, 1));
    await gateway.login('20260000001', 'secret-value');
    await gateway.submitLoginCaptcha('ok');
    expect((await gateway.listTerms()).data, isNotEmpty);
    const term = TermRef(xn: '2026', xq: '0', label: '2026-2027学年第一学期');
    final synced = await gateway.syncSchedule(term);
    expect(synced.ok, isTrue);
    expect(synced.data!.courses.single.courseName, '高等数学');
    final edited = synced.data!.courses.map((course) => course.copy()).toList();
    edited[0] = CourseRecord(
      courseCode: edited[0].courseCode,
      courseName: edited[0].courseName,
      sectionId: edited[0].sectionId,
      credit: edited[0].credit,
      teacherName: edited[0].teacherName,
      meetings: [CourseMeeting(weekday: 1, periodStart: 1, periodEnd: 2, place: '知敬楼202', weeks: const [1])],
    );
    await gateway.saveScheduleRevision(term, edited, '改教室', expectedRevisionId: (await gateway.readSchedule(const ScheduleScope.term(term))).data!.revisionId);
    final plan = await gateway.planScheduleSync(term, synced.data!.courses);
    expect(plan.data?.conflict, isTrue);
    final denied = await gateway.commitScheduleSync(term, synced.data!.courses, confirm: false);
    expect(denied.ok, isFalse);
    expect(denied.error?.code, 'SYNC_CONFLICT');
    await gateway.commitScheduleSync(term, synced.data!.courses, confirm: true, expectedRevisionId: plan.data!.revisionId);
    final reopened = KingoCampusGateway(database: database, client: _FakeKingo(), now: () => DateTime.utc(2026, 9, 24, 2));
    final revisions = await reopened.listScheduleRevisions(term);
    expect(revisions.data, hasLength(3));
    final user = revisions.data!.firstWhere((row) => row.summary == '改教室');
    await reopened.restoreScheduleRevision(term, user.id, expectedRevisionId: (await reopened.readSchedule(const ScheduleScope.term(term))).data!.revisionId);
    final view = await reopened.readSchedule(const ScheduleScope.currentTerm(term));
    expect(view.data!.courses.single.meetings.single.place, '知敬楼202');
  });

  test('开学日、成绩和作息分别写入 term、grades_cache、bells_cache', () async {
    final database = await AppDatabase.openMemory();
    final gateway = KingoCampusGateway(database: database, client: _FakeKingo(), now: () => DateTime.utc(2026, 9, 24, 3));
    await gateway.login('20260000001', 'secret-value');
    await gateway.submitLoginCaptcha('ok');
    expect((await gateway.listTerms()).data, isNotEmpty);
    const term = TermRef(xn: '2026', xq: '0', label: '2026-2027学年第一学期');
    await gateway.setTermStart(term, '2024-01-03');
    await gateway.syncGrades(term);
    await gateway.syncBells(term);

    expect(await database.termStartDate('2026', '0'), '2024-01-03');
    final grades = jsonDecode((await database.gradesPayload('2026', '0'))!) as Map<String, Object?>;
    final effective = grades['effective'] as List<dynamic>;
    expect((effective.single as Map)['courseName'], '高等数学');
    expect((effective.single as Map)['score'], 87);
    expect((grades['summary'] as Map)['gpa'], 3.15);
    final bells = await database.bellsRow('2026', '0');
    final periods = jsonDecode(bells!['periods_json'] as String) as List<dynamic>;
    expect((periods.single as Map)['start'], '08:00');
    expect(bells['empty'], 0);

    final reopened = KingoCampusGateway(database: database, client: _FakeKingo(), now: () => DateTime.utc(2026, 9, 24, 4));
    final cachedGrades = await reopened.readGrades(term);
    expect(cachedGrades.source, 'local');
    expect(cachedGrades.data!.effective.single.score, 87);
    final cachedBells = await reopened.readBells(term);
    expect(cachedBells.data!.periods.single.start, '08:00');
    await reopened.syncSchedule(term);
    final day = await reopened.readSchedule(const ScheduleScope.day(term: term, date: '2024-01-01', termStartDate: ''));
    expect(day.ok, isTrue);
    expect(day.data!.courses, isNotEmpty);
  });
}

class _FakeKingo extends KingoClient {
  @override
  Future<KingoLoginResult> login(String username, String password, {String captcha = ''}) async {
    if (captcha.isEmpty) {
      pageSession = 'SESSION';
      return KingoLoginResult(
        ok: false,
        needsCaptcha: true,
        failure: null,
        captcha: const CaptchaViewData(prompt: '请输入图中的验证码', hint: '请输入图中的验证码', contentType: 'image/jpeg', imageBase64: 'aa'),
        loginId: null,
      );
    }
    if (captcha == 'bad') {
      return const KingoLoginResult(
        ok: false,
        needsCaptcha: true,
        failure: null,
        captcha: CaptchaViewData(prompt: '请输入图中的验证码', hint: '验证码不正确，请重新输入', contentType: 'image/jpeg', imageBase64: 'bb'),
        loginId: null,
      );
    }
    jar['JSESSIONID'] = 'abc';
    pageSession = 'SESSION';
    return const KingoLoginResult(
      ok: true,
      needsCaptcha: false,
      failure: null,
      captcha: null,
      loginId: '20260000001',
      userCode: 'U1',
      currentXn: '2026',
      currentXq: '0',
      terms: [(xn: '2026', xq: '0', label: '2026-2027学年第一学期')],
    );
  }

  @override
  Future<ParsedSchedule> fetchSchedule({required String xn, required String xq, required String userCode}) async {
    return ParsedSchedule(
      termLabel: '2026-2027学年第一学期',
      loginId: '20260000001',
      name: '测试',
      className: '计算机',
      courses: [
        CourseRecord(
          courseCode: 'C1',
          courseName: '高等数学',
          sectionId: 'S1',
          credit: 4,
          teacherName: '王',
          meetings: [CourseMeeting(weekday: 1, periodStart: 1, periodEnd: 2, place: '知敬楼101', weeks: const [1])],
        ),
      ],
    );
  }

  @override
  Future<({String rxnj, String nj})> fetchGradeForm() async => (rxnj: '2025', nj: '2025');

  @override
  Future<({ParsedGrades effective, ParsedGrades original})> fetchGrades({
    required String xn,
    required String xq,
    required String rxnj,
    required String nj,
  }) async {
    const course = ParsedGradeCourse(courseCode: 'C1', courseName: '高等数学', credit: 4, score: 87, earnedCredit: 4, gradePoint: 3.7);
    const header = ParsedGrades(
      loginId: '20260000001',
      name: '测试',
      college: '人工智能学院',
      major: '计算机科学与技术',
      level: '本科',
      className: '计算机',
      termLabel: '2026-2027学年第一学期',
      courses: [course],
      summary: [GradeHeader(category: '合计', earnedCredit: 4, gpa: 3.15, averageScore: 87, weightedAverage: 87)],
    );
    return (effective: header, original: header);
  }

  @override
  Future<ParsedBells> fetchBells({required String xn, required String xq}) async {
    return const ParsedBells(
      empty: false,
      message: '',
      termLabel: '2026-2027学年第一学期作息时间',
      periods: [ParsedBell(period: 1, dayPart: '上午', dayPartCode: 'morning', start: '08:00', end: '08:45')],
    );
  }
}
