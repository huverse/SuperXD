import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:superxd/application/campus_sync.dart';
import 'package:superxd/edu/kingo_client.dart';
import 'package:superxd/edu/parse_bells.dart';
import 'package:superxd/edu/parse_schedule.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/gateway/fixture_gateway.dart';
import 'package:superxd/gateway/kingo_campus_gateway.dart';
import 'package:superxd/local/app_database.dart';
import 'package:superxd/domain/schedule_store.dart';

const _term = TermRef(xn: '2026', xq: '0');

void main() {
  test('保留标题但查询失败的空表拒绝作为空课程', () {
    expect(() => parseScheduleHtml('<h1>学生个人课表</h1><p>查询失败</p><tbody></tbody>'), throwsFormatException);
    expect(() => parseScheduleHtml('<h1>学生个人课表</h1><p>没有访问权限</p><tbody></tbody>'), throwsFormatException);
  });

  test('单节次可解析，非空未知时间格式不能被静默丢弃', () {
    final course = parseScheduleHtml(_schedule('3-18周 三[1] 教室')).courses.single;
    expect(course.meetings.single.periodStart, 1);
    expect(course.meetings.single.periodEnd, 1);
    expect(() => parseScheduleHtml(_schedule('暂未支持的上课时间')), throwsFormatException);
    expect(() => parseScheduleHtml(_schedule('abc周 三[1] 教室')), throwsFormatException);
  });

  test('教师学分变化会同步，课程和周次重排不生成多余版本', () {
    CourseRecord course({String teacher = '原教师', num credit = 1, List<int> weeks = const [1, 2]}) => CourseRecord(
      courseCode: 'C', courseName: '课程', sectionId: 'S', teacherName: teacher, credit: credit,
      meetings: [CourseMeeting(weekday: 1, periodStart: 1, periodEnd: 2, place: '教室', weeks: weeks)],
    );
    final store = ScheduleStore();
    store.commitSync(_term, [course()], confirm: false, now: 'stamp');
    expect(store.planSync(_term, [course(teacher: '新教师')]).action, 'insert');
    expect(store.planSync(_term, [course(credit: 2)]).action, 'insert');
    expect(store.planSync(_term, [course(weeks: [2, 1])]).action, 'unchanged');
  });

  test('坏作息和重复节次不覆盖已保存时间', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final db = await AppDatabase.openMemory();
    final client = _BellsClient();
    final gateway = KingoCampusGateway(database: db, client: client);
    expect((await gateway.syncBells(_term)).ok, isTrue);
    client.periods = [const ParsedBell(period: 1, dayPart: '上午', dayPartCode: 'morning', start: '99:00', end: '10:00')];
    expect((await gateway.syncBells(_term)).error?.code, 'UPSTREAM_FORMAT');
    expect((await gateway.readBells(_term)).data!.periods.single.start, '08:00');
    client.periods = [client.valid, client.valid];
    expect((await gateway.syncBells(_term)).error?.code, 'UPSTREAM_FORMAT');
    expect((await gateway.readBells(_term)).data!.periods.single.start, '08:00');
    await db.close();
  });

  test('等待期间离开页面，失效早退也携带取消标记', () async {
    final gateway = _PendingGateway();
    var active = true;
    final future = CampusSync(gateway).run(contents: {SyncContent.schedule}, isActive: () => active,
      confirmSchedule: (_, _) async => false, chooseBells: (_, _) async => BellsChoice.cancel);
    await gateway.started.future;
    active = false;
    gateway.pending.complete(const GatewayResult<ScheduleView>(ok: false, source: 'edu', fetchedAt: 'stamp', error: GatewayError(code: 'SESSION_EXPIRED', message: '过期')));
    final report = await future;
    expect(report.sessionExpired, isTrue);
    expect(report.cancelled, isTrue);
  });
}

String _schedule(String meeting) {
  final cells = ['S', '班', '[C]课程', '32', '1', '初修', '[T]教师', '选中', '否', '是', meeting, ''];
  return '<h1>学生个人课表</h1><p>课程门数：1</p><tbody><tr>${cells.map((cell) => '<td>$cell</td>').join()}</tr></tbody>';
}

class _BellsClient extends KingoClient {
  final valid = const ParsedBell(period: 1, dayPart: '上午', dayPartCode: 'morning', start: '08:00', end: '08:45');
  late List<ParsedBell> periods = [valid];
  @override
  Future<ParsedBells> fetchBells({required String xn, required String xq}) async => ParsedBells(empty: false, message: '', termLabel: '作息', periods: periods);
}

class _PendingGateway extends FixtureCampusGateway {
  _PendingGateway() : super(readText: (name) => File('assets/fixtures/$name').readAsString());
  final started = Completer<void>();
  final pending = Completer<GatewayResult<ScheduleView>>();
  @override
  Future<GatewayResult<List<TermRef>>> syncTerms() async => const GatewayResult(ok: true, source: 'edu', fetchedAt: 'stamp', data: [_term]);
  @override
  Future<GatewayResult<ScheduleView>> syncSchedule(TermRef term) {
    started.complete();
    return pending.future;
  }
}
