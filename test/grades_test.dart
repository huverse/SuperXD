import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:superxd/edu/kingo_client.dart';
import 'package:superxd/edu/parse_grades.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/gateway/kingo_campus_gateway.dart';
import 'package:superxd/local/app_database.dart';
import 'package:superxd/domain/grades.dart' as grades;
import 'package:superxd/domain/schedule_store.dart';

const term = TermRef(xn: '2025', xq: '0', label: '2025-2026学年第一学期');
const student = SessionView(loginId: 'test', name: '', className: '');
String transcript({
  bool original = false,
  String account = 'test',
  String label = '2025-2026学年第一学期',
  String score = '87.5',
  bool empty = false,
  bool categoryOnly = false,
}) =>
    '''
<h1>学生成绩</h1><table group="group"><tr><td>学号：$account</td><td>姓名：测试</td><td>学年学期：$label</td></tr></table>
<table><tr>${(original ? ['序号', '课程', '学分', '平时成绩', '期中成绩', '期末成绩', '技能成绩', '总评成绩'] : ['序号', '课程', '学分', '成绩', '获得学分', '绩点']).map((label) => '<th>$label</th>').join()}</tr>
${empty ? '<tr><td colspan="8">没有成绩记录</td></tr>' : '<tr>${(original ? ['1', '[C1]课程&amp;甲', '2', '90', '', '80', '', score] : ['1', '[C1]课程&amp;甲', '2', score, '2', '3.5']).map((cell) => '<td>$cell</td>').join()}</tr>'}</table>
${original ? '' : '<table><tr><th>类别</th><th>获得学分</th><th>平均学分绩点</th><th>平均分</th><th>加权平均分</th></tr><tr><td>${categoryOnly ? '必修' : '合计'}</td><td>2</td><td>3.5</td><td>87.5</td><td>87.5</td></tr></table>'}
''';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  test('DOM按列名解析实体、原始分项、真实零值与等级文本', () {
    final effective = parseEffectiveGrades(transcript(score: '0'));
    expect(effective.loginId, 'test');
    expect(effective.termLabel, term.label);
    expect(effective.courses.single.courseName, '课程&甲');
    expect(effective.courses.single.score, 0);
    final original = parseOriginalGrades(
      transcript(original: true, score: '合格'),
    );
    expect(original.courses.single.midtermScore, isNull);
    expect(original.courses.single.totalScore, '合格');
    expect(effective.summary.single.gpa, 3.5);
  });
  test('真实学校表头别名分清绩点和学分绩点，综合成绩映射总评', () {
    final effective = transcript()
        .replaceAll('<th>课程</th>', '<th>课程/环节</th>')
        .replaceAll('<th>绩点</th>', '<th>绩点</th><th>学分绩点</th>')
        .replaceFirst('<td>3.5</td></tr>', '<td>3.5</td><td>7</td></tr>')
        .replaceAll('平均学分绩点', '获得平均学分绩点');
    expect(parseEffectiveGrades(effective).courses.single.gradePoint, 3.5);
    expect(parseEffectiveGrades(effective).summary.single.gpa, 3.5);
    final original = transcript(original: true)
        .replaceAll('总评成绩', '综合成绩')
        .replaceAll('<th>课程</th>', '<th>课程/环节</th>');
    expect(parseOriginalGrades(original).courses.single.totalScore, 87.5);
  });
  test('成绩列换位不会错读，重复同课程行全部保留', () {
    final body = transcript()
        .replaceFirst('<th>成绩</th><th>获得学分</th>', '<th>获得学分</th><th>成绩</th>')
        .replaceFirst('<td>87.5</td><td>2</td>', '<td>2</td><td>87.5</td>');
    expect(parseEffectiveGrades(body).courses.single.score, 87.5);
    final row = RegExp(r'<tr><td>1</td>.*?</tr>').firstMatch(body)!.group(0)!;
    final two = body.replaceFirst(
      row,
      '$row${row.replaceFirst('<td>1</td>', '<td>2</td>')}',
    );
    expect(parseEffectiveGrades(two).courses, hasLength(2));
  });
  test('明确空成绩接受，错误页和缺列拒绝，不把标题当数据', () {
    expect(parseEffectiveGrades(transcript(empty: true)).courses, isEmpty);
    expect(
      () => parseEffectiveGrades('${transcript()}<p>成绩记录数：2</p>'),
      throwsFormatException,
    );
    for (final body in [
      '<h1>学生成绩</h1><table></table>',
      '<h1>学生成绩</h1><table><tr><td>没有访问权限</td></tr></table>',
      transcript().replaceFirst('<td>87.5</td>', ''),
      transcript().replaceFirst('<th>获得学分</th>', '<th>未知列</th>'),
    ]) {
      expect(() => parseEffectiveGrades(body), throwsFormatException);
    }
  });
  test('JSON边界不吞损坏、学校文本不变0、排序等级置后且稳定', () {
    final courses = [
      const GradeCourse(courseCode: '1', courseName: '未公布', credit: null),
      const GradeCourse(courseCode: '2', courseName: '零分', credit: 1, score: 0),
      const GradeCourse(
        courseCode: '3',
        courseName: '合格',
        credit: '免修',
        score: '合格',
      ),
      const GradeCourse(
        courseCode: '4',
        courseName: '高分',
        credit: 2,
        score: 90,
      ),
    ];
    expect(
      grades
          .selectGrades(courses, original: false, sort: grades.GradeSort.high)
          .map((course) => course.courseName),
      ['高分', '零分', '未公布', '合格'],
    );
    expect(
      grades
          .selectGrades(
            courses,
            original: false,
            filter: grades.GradeFilter.unpublished,
          )
          .single
          .courseName,
      '未公布',
    );
    expect(grades.gradeText(0), '0');
    expect(grades.gradeText(null), '教务未提供');
    expect(
      () => grades.decodeGradeJson('{bad'),
      throwsA(isA<grades.GradeDataException>()),
    );
  });

  group('缓存安全', () {
    late AppDatabase database;
    late KingoCampusGateway gateway;
    late _Client client;
    setUp(() async {
      database = await AppDatabase.openMemory();
      await database.saveTerms([
        term,
        const TermRef(xn: '2025', xq: '1'),
        const TermRef(xn: '2026', xq: '0'),
      ]);
      await database.writeSession(
        const SavedSession(
          loginId: 'test',
          displayName: '',
          className: '',
          cookieJson: '{}',
          savedAt: '2026-01-01T00:00:00Z',
        ),
      );
      client = _Client();
      gateway = KingoCampusGateway(
        database: database,
        client: client,
        now: () => DateTime.utc(2026, 9, 25),
      );
    });
    tearDown(() async {
      client.dispose();
      await database.close();
    });
    test('成功后保留真实同步时间，分类汇总不冒充合计，原始请求失败不半写', () async {
      expect((await gateway.syncGrades(term)).ok, isTrue);
      client.fail = true;
      expect((await gateway.syncGrades(term)).ok, isFalse);
      final cached = await gateway.readGrades(term);
      expect(cached.fetchedAt, '2026-09-25T00:00:00.000Z');
      expect(cached.data!.effective.single.score, 87.5);
      client.fail = false;
      client.categoryOnly = true;
      expect((await gateway.syncGrades(term)).data!.summary, isNull);
      expect(
        (await gateway.readGrades(term)).data!.summaries.single.category,
        '必修',
      );
    });
    test('身份和学期不匹配拒绝更新，空与未同步有区别', () async {
      expect((await gateway.readGrades(term)).data!.cached, isFalse);
      expect((await gateway.syncGrades(term)).ok, isTrue);
      client.account = 'other';
      expect(
        (await gateway.syncGrades(term)).error?.code,
        'GRADE_DATA_INVALID',
      );
      client.account = 'test';
      client.label = '2024-2025学年第一学期';
      expect((await gateway.syncGrades(term)).ok, isFalse);
      expect((await gateway.readGrades(term)).data!.effective, hasLength(1));
      client.label = term.label;
      client.empty = true;
      expect((await gateway.syncGrades(term)).data!.empty, isTrue);
      expect((await gateway.readGrades(term)).data!.cached, isTrue);
    });
    test('真实无抬头空页核对身份后保存，但不清空已有非空成绩', () async {
      client.headerless = true;
      client.empty = true;
      expect((await gateway.syncGrades(term)).ok, isTrue);
      expect(client.profiles, 1);
      client.headerless = false;
      client.empty = false;
      expect((await gateway.syncGrades(term)).ok, isTrue);
      final before = (await gateway.readGrades(term)).fetchedAt;
      client.headerless = true;
      client.empty = true;
      expect(
        (await gateway.syncGrades(term)).error?.code,
        'GRADE_DATA_INVALID',
      );
      expect((await gateway.readGrades(term)).data!.effective, hasLength(1));
      expect((await gateway.readGrades(term)).fetchedAt, before);
    });
    test('同学期并发合并一次，不同学期不排无界请求，结束释放', () async {
      client.gate = Completer<void>();
      final first = gateway.syncGrades(term);
      final second = gateway.syncGrades(term);
      expect(
        (await gateway.syncGrades(const TermRef(xn: '2025', xq: '1')))
            .error
            ?.code,
        'SYNC_BUSY',
      );
      client.gate!.complete();
      expect((await first).ok, isTrue);
      expect((await second).ok, isTrue);
      expect(client.calls, 1);
      expect((await gateway.syncGrades(term)).ok, isTrue);
      expect(client.calls, 2);
    });
    test('学年只读本年摘要，旧缓存惰性补齐，坏缓存不吞成空', () async {
      final view = GradesView(
        message: '',
        empty: false,
        term: term,
        student: student,
        summary: null,
        effective: const [
          GradeCourse(courseCode: 'C', courseName: '旧课程', credit: 1, score: 0),
        ],
        original: const [],
      );
      await database.writeGrades(
        term.xn,
        term.xq,
        '2020-01-01T00:00:00Z',
        jsonEncode(grades.gradesJson(view)),
      );
      final year = await gateway.readGradeYear('2025');
      expect(year.data, hasLength(2));
      expect(year.data!.first.fetchedAt, '2020-01-01T00:00:00Z');
      expect(year.data!.last.cached, isFalse);
      expect((await database.gradesRow(term))!['summary_json'], isNotNull);
      await database.writeGrades(
        term.xn,
        term.xq,
        '2020-01-01T00:00:00Z',
        '{}',
      );
      expect((await gateway.readGrades(term)).ok, isFalse);
      expect(
        (await gateway.readGradeYear('2025')).data!.first.error,
        isNotNull,
      );
      expect(client.calls, 0);
    });
  });

  test('文件关闭重开后成绩时间保持，v4缓存升级保留', () async {
    final directory = await Directory.systemTemp.createTemp('grades-db-');
    final path = '${directory.path}/account.db';
    var database = await AppDatabase.open(databasePath: path);
    await database.saveTerms([term]);
    final view = GradesView(
      message: '',
      empty: true,
      term: term,
      student: student,
      summary: null,
      effective: const [],
      original: const [],
    );
    await database.writeGrades(
      term.xn,
      term.xq,
      '2020-01-01T00:00:00Z',
      jsonEncode(grades.gradesJson(view)),
    );
    await database.close();
    final raw = await openDatabase(path);
    await raw.execute('ALTER TABLE grades_cache DROP COLUMN summary_json');
    await raw.setVersion(4);
    await raw.close();
    database = await AppDatabase.open(databasePath: path);
    final result = await KingoCampusGateway(database: database)
        .readGrades(term);
    expect(result.data!.cached, isTrue);
    expect(result.data!.empty, isTrue);
    expect(result.fetchedAt, '2020-01-01T00:00:00Z');
    final inspect = await openDatabase(path, singleInstance: false);
    final plan = await inspect.rawQuery(
      'EXPLAIN QUERY PLAN SELECT summary_json FROM grades_cache WHERE xn = ? AND xq = ? LIMIT 1',
      [term.xn, term.xq],
    );
    expect(plan.toString(), contains('INDEX'));
    await inspect.close();
    await database.close();
    await directory.delete(recursive: true);
  });

  test('HTTP成绩正文超限中止且超时仍覆盖正文', () async {
    final client = KingoClient(
      client: MockClient(
        (_) async => http.Response('x' * (grades.gradePayloadLimit + 1), 200),
      ),
    );
    await expectLater(
      client.fetchGrades(xn: '2025', xq: '0', rxnj: '2025', nj: '2025'),
      throwsFormatException,
    );
    client.dispose();
  });
}

class _Client extends KingoClient {
  bool fail = false;
  bool categoryOnly = false;
  bool empty = false;
  bool headerless = false;
  int profiles = 0;
  @override
  Future<KingoProfile> fetchProfile() async {
    profiles++;
    return KingoProfile(
      userCode: 'user',
      xn: '2025',
      xq: '0',
      loginId: account,
    );
  }

  String account = 'test';
  String label = term.label;
  int calls = 0;
  Completer<void>? gate;
  @override
  Future<({String rxnj, String nj})> fetchGradeForm() async =>
      (rxnj: '2025', nj: '2025');
  @override
  Future<({ParsedGrades effective, ParsedGrades original})> fetchGrades({
    required String xn,
    required String xq,
    required String rxnj,
    required String nj,
  }) async {
    calls++;
    if (gate != null) await gate!.future;
    if (headerless) {
      return (
        effective: parseEffectiveGrades(
          '<h1>学生成绩</h1><center>没有检索到记录!</center>',
        ),
        original: parseOriginalGrades('<h1>学生成绩</h1><center>没有检索到记录!</center>'),
      );
    }
    final effective = parseEffectiveGrades(
      transcript(
        account: account,
        label: label,
        empty: empty,
        categoryOnly: categoryOnly,
      ),
    );
    if (fail) throw const FormatException('原始成绩响应失败');
    return (
      effective: effective,
      original: parseOriginalGrades(
        transcript(
          original: true,
          account: account,
          label: label,
          empty: empty,
        ),
      ),
    );
  }
}
