import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:superxd/local/app_database.dart';
import 'package:superxd/domain/schedule_store.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  test('真实v3结构迁移按插入序号保留100版，保护早期head和教务基线', () async {
    final directory = await Directory.systemTemp.createTemp('schedule-v3-');
    final path = '${directory.path}/v3.db';
    final old = await openDatabase(
      path,
      version: 3,
      onCreate: (db, _) async {
        await db.execute(
          'CREATE TABLE term (xn TEXT, xq TEXT, label TEXT, is_current INTEGER DEFAULT 0, start_date TEXT, PRIMARY KEY(xn,xq))',
        );
        await db.execute(
          'CREATE TABLE schedule_revision (id TEXT PRIMARY KEY, xn TEXT, xq TEXT, source TEXT, parent_id TEXT, created_at TEXT, summary TEXT, courses_json TEXT)',
        );
        await db.execute(
          'CREATE TABLE schedule_head (xn TEXT, xq TEXT, revision_id TEXT, PRIMARY KEY(xn,xq), FOREIGN KEY(revision_id) REFERENCES schedule_revision(id))',
        );
        await db.execute(
          'CREATE INDEX schedule_revision_term_created ON schedule_revision(xn,xq,created_at,id)',
        );
      },
    );
    final batch = old.batch();
    batch.insert('term', {
      'xn': '2026',
      'xq': '0',
      'label': '旧学期',
      'start_date': '2026-08-31',
    });
    for (var index = 0; index < 120; index++) {
      batch.insert('schedule_revision', {
        'id': 'r$index',
        'xn': '2026',
        'xq': '0',
        'source': index == 0 ? 'edu' : 'user',
        'parent_id': index == 0 ? null : 'r${index - 1}',
        'created_at': index == 119
            ? '2020-01-01T00:00:00Z'
            : '2026-01-01T00:00:00Z',
        'summary': '版本$index',
        'courses_json': jsonEncode([
          {
            'courseCode': 'C',
            'sectionId': 'S',
            'courseName': '课程$index',
            'teacherName': '',
            'meetings': [],
          },
        ]),
      });
    }
    batch.insert('schedule_head', {
      'xn': '2026',
      'xq': '0',
      'revision_id': 'r1',
    });
    await batch.commit(noResult: true);
    await old.close();
    final database = await AppDatabase.open(databasePath: path);
    const term = TermRef(xn: '2026', xq: '0');
    final rows = await database.revisionPage(term, limit: 100);
    expect(rows, hasLength(100));
    expect(rows.first['id'], 'r119');
    expect(rows.map((row) => row['id']), containsAll(['r0', 'r1']));
    expect(await database.readRevision(term, 'r2'), isNull);
    expect(
      (await database.loadTermStore(term))
          .head(term)!
          .courses
          .single
          .courseName,
      '课程1',
    );
    expect(await database.termStartDate(term.xn, term.xq), '2026-08-31');
    final result = await database.saveSchedule(
      term,
      [],
      '清空',
      expectedRevisionId: 'r1',
      now: '2020-01-01T00:00:00Z',
    );
    expect((await database.revisionPage(term)).first['sequence'], 121);
    expect((await database.readRevision(term, result.id))!.courses, isEmpty);
    await database.close();
    await directory.delete(recursive: true);
  });
}
