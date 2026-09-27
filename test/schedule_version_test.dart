import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:superxd/gateway/kingo_campus_gateway.dart';
import 'package:superxd/local/app_database.dart';
import 'package:superxd/local/schedule_store.dart';

const term = TermRef(xn: '2026', xq: '0');
List<CourseRecord> courses(String name) => [
  CourseRecord(
    courseCode: 'C',
    courseName: name,
    sectionId: 'S',
    credit: 1,
    teacherName: '',
    meetings: [
      CourseMeeting(
        weekday: 1,
        periodStart: 1,
        periodEnd: 2,
        place: '101',
        weeks: [1, 2, 3],
      ),
    ],
  ),
];

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  late Directory directory;
  late AppDatabase database;
  late KingoCampusGateway gateway;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('schedule-version-');
    database = await AppDatabase.open(
      databasePath: '${directory.path}/account.db',
    );
    gateway = KingoCampusGateway(
      database: database,
      now: () => DateTime.utc(2026),
    );
  });
  tearDown(() async {
    await database.close();
    await directory.delete(recursive: true);
  });

  test('并发编辑只有一个成功，过时恢复和确认不能覆盖新head', () async {
    final baseline = await gateway.commitScheduleSync(
      term,
      courses('教务'),
      confirm: false,
    );
    final base = baseline.data!.id;
    final results = await Future.wait([
      gateway.saveScheduleRevision(
        term,
        courses('修改A'),
        'A',
        expectedRevisionId: base,
      ),
      gateway.saveScheduleRevision(
        term,
        courses('修改B'),
        'B',
        expectedRevisionId: base,
      ),
    ]);
    expect(results.where((result) => result.ok), hasLength(1));
    expect(
      results.where((result) => result.error?.code == 'REVISION_CONFLICT'),
      hasLength(1),
    );
    expect(
      (await gateway.restoreScheduleRevision(
        term,
        base,
        expectedRevisionId: base,
      )).error?.code,
      'REVISION_CONFLICT',
    );
    expect(
      (await gateway.commitScheduleSync(
        term,
        courses('外部'),
        confirm: true,
        expectedRevisionId: base,
      )).error?.code,
      'REVISION_CONFLICT',
    );
    expect(
      (await gateway.commitScheduleSync(
        term,
        courses('外部'),
        confirm: false,
      )).error?.code,
      'SYNC_CONFLICT',
    );
    expect((await gateway.listScheduleRevisions(term)).data, hasLength(2));
  });

  test('同时间与回拨仍按提交序号排序，无变化保存不新增，文件重开保持', () async {
    final first = await gateway.saveScheduleRevision(
      term,
      courses('一'),
      '一',
      expectedRevisionId: null,
    );
    final second = await gateway.saveScheduleRevision(
      term,
      courses('二'),
      '二',
      expectedRevisionId: first.data!.id,
    );
    final duplicate = await gateway.saveScheduleRevision(
      term,
      courses('二'),
      '不应出现',
      expectedRevisionId: second.data!.id,
    );
    expect(duplicate.data!.id, second.data!.id);
    gateway = KingoCampusGateway(
      database: database,
      now: () => DateTime.utc(2020),
    );
    final third = await gateway.saveScheduleRevision(
      term,
      courses('三'),
      '三',
      expectedRevisionId: second.data!.id,
    );
    expect(third.ok, isTrue);
    await database.close();
    database = await AppDatabase.open(
      databasePath: '${directory.path}/account.db',
    );
    gateway = KingoCampusGateway(database: database);
    final history = (await gateway.listScheduleRevisions(term)).data!;
    expect(history.map((row) => row.summary), ['三', '二', '一']);
    expect(history.map((row) => row.sequence), [3, 2, 1]);
    expect(history.first.current, isTrue);
    expect(history.skip(1).any((row) => row.current), isFalse);
  });

  test('100版保留head和教务基线，游标分页不重复，清理的版本不可恢复', () async {
    final edu = await gateway.commitScheduleSync(
      term,
      courses('教务基线'),
      confirm: false,
    );
    var head = edu.data!.id;
    String? removed;
    for (var index = 0; index < 105; index++) {
      final saved = await gateway.saveScheduleRevision(
        term,
        courses('课程$index'),
        '修改$index',
        expectedRevisionId: head,
      );
      expect(saved.ok, isTrue);
      head = saved.data!.id;
      removed ??= head;
    }
    final all = <String>[];
    int? cursor;
    for (var page = 0; page < 6; page++) {
      final rows = (await gateway.listScheduleRevisions(
        term,
        beforeSequence: cursor,
      )).data!;
      if (rows.isEmpty) break;
      expect(rows.length, lessThanOrEqualTo(20));
      all.addAll(rows.map((row) => row.id));
      cursor = rows.last.sequence;
    }
    expect(all, hasLength(100));
    expect(all.toSet(), hasLength(100));
    expect(all.first, head);
    expect(all.last, edu.data!.id);
    expect(
      (await gateway.readScheduleRevision(term, removed!)).error?.code,
      'REVISION_MISSING',
    );
    expect(
      (await gateway.restoreScheduleRevision(
        term,
        edu.data!.id,
        expectedRevisionId: head,
      )).data!.source,
      'user',
    );
    expect(
      (await gateway.commitScheduleSync(
        term,
        courses('更新教务'),
        confirm: false,
      )).error?.code,
      'SYNC_CONFLICT',
    );
  });

  test('插入head故障整个事务回滚，旧课程和历史不变', () async {
    final saved = await gateway.saveScheduleRevision(
      term,
      courses('原课'),
      '原课',
      expectedRevisionId: null,
    );
    final raw = await openDatabase(
      database.databasePath,
      singleInstance: false,
    );
    await raw.execute(
      "CREATE TRIGGER fail_head BEFORE UPDATE ON schedule_head BEGIN SELECT RAISE(ABORT, 'test failure'); END",
    );
    final result = await gateway.saveScheduleRevision(
      term,
      courses('新课'),
      '新课',
      expectedRevisionId: saved.data!.id,
    );
    expect(result.ok, isFalse);
    expect(
      (await database.loadTermStore(term))
          .head(term)!
          .courses
          .single
          .courseName,
      '原课',
    );
    expect((await gateway.listScheduleRevisions(term)).data, hasLength(1));
    await raw.execute('DROP TRIGGER fail_head');
    await raw.close();
  });

  test('历史查询与基线保护查询使用对应索引', () async {
    final raw = await openDatabase(
      database.databasePath,
      singleInstance: false,
    );
    final plan = await raw.rawQuery(
      'EXPLAIN QUERY PLAN SELECT id, summary FROM schedule_revision WHERE xn = ? AND xq = ? AND sequence < ? ORDER BY sequence DESC LIMIT 20',
      ['2026', '0', 1000],
    );
    expect(plan.toString(), contains('schedule_revision_term_sequence'));
    expect(plan.toString(), isNot(contains('TEMP B-TREE')));
    final edu = await raw.rawQuery(
      "EXPLAIN QUERY PLAN SELECT id FROM schedule_revision WHERE xn = ? AND xq = ? AND source = 'edu' ORDER BY sequence DESC LIMIT 1",
      ['2026', '0'],
    );
    expect(edu.toString(), contains('schedule_revision_term_source_sequence'));
    await raw.close();
  });

  test('跨学期读取恢复不能命中其他学期版本', () async {
    final saved = await gateway.saveScheduleRevision(
      term,
      courses('一'),
      '一',
      expectedRevisionId: null,
    );
    const other = TermRef(xn: '2025', xq: '0');
    expect(
      (await gateway.readScheduleRevision(other, saved.data!.id)).error?.code,
      'REVISION_MISSING',
    );
    expect(
      (await gateway.restoreScheduleRevision(
        other,
        saved.data!.id,
        expectedRevisionId: null,
      )).error?.code,
      'REVISION_MISSING',
    );
  });
}
