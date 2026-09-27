import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:superxd/gateway/account_access.dart';
import 'package:superxd/local/account_store.dart';
import 'package:superxd/local/app_database.dart';
import 'package:superxd/local/schedule_store.dart';

const a = AccountIdentity(source: 'https://school.example/edu', loginId: 'A');
const b = AccountIdentity(source: 'https://school.example/edu', loginId: 'B');
const term = TermRef(xn: '2025', xq: '0', label: '旧学期');
const other = TermRef(xn: '2026', xq: '0', label: '新学期');

void main() {
  setUpAll(() { sqfliteFfiInit(); databaseFactory = databaseFactoryFfi; });

  for (final version in [1, 2]) {
    test('旧v$version必须确认才导入，保留session/current/head/cache冲突，重复导入幂等', () async {
      final dir = await Directory.systemTemp.createTemp('superxd-legacy-');
      final path = '${dir.path}/superxd.db';
      final legacy = await AppDatabase.open(databasePath: path);
      await legacy.saveTerms([term, other], currentXn: term.xn, currentXq: term.xq);
      await legacy.setTermStart(term, '2025-09-01');
      await legacy.writeSession(const SavedSession(loginId: 'old', displayName: 'old', className: '', cookieJson: 'never-copy-this', savedAt: 'old'));
      // 直接构造真正的超限旧历史，不能使用新版的去重和保留策略造夹具。
      final fixture = await openDatabase(path, singleInstance: false);
      final batch = fixture.batch();
      for (var index = 0; index < 205; index++) {
        batch.insert('schedule_revision', {'id': 'old-$index', 'xn': term.xn, 'xq': term.xq, 'source': 'user', 'parent_id': index == 0 ? null : 'old-${index - 1}', 'created_at': '2025-09-01T00:00:00Z', 'summary': 'old-$index', 'sequence': index + 1, 'courses_json': '[]'});
      }
      batch.insert('schedule_head', {'xn': term.xn, 'xq': term.xq, 'revision_id': 'old-204'});
      await batch.commit(noResult: true);
      await fixture.close();
      await legacy.writeGrades(term.xn, term.xq, 'old', '{"old":true}');
      await legacy.writeBells(xn: term.xn, xq: term.xq, fetchedAt: 'old', empty: false, message: '', periodsJson: '[{"period":1,"start":"08:00","end":"08:45"}]');
      await legacy.setBellsSource(targetXn: other.xn, targetXq: other.xq, sourceXn: term.xn, sourceXq: term.xq);
      await legacy.close();
      final raw = await openDatabase(path, singleInstance: false);
      await raw.execute('DROP TABLE account_owner');
      await raw.execute('DROP TABLE legacy_import_marker');
      if (version == 1) await raw.execute('DROP TABLE term_bells_source');
      await raw.setVersion(version);
      await raw.close();
      final before = await File(path).readAsBytes();

      final store = await AccountStore.open(directory: dir.path);
      final target = await store.openAccount(a);
      expect(await target.terms(), isEmpty);
      expect((await store.legacyState(a)).available, isTrue);
      await store.deferLegacy(a);
      expect((await store.legacyState(a)).deferred, isTrue);
      await target.saveTerms([term, other], currentXn: other.xn, currentXq: other.xq);
      await target.setTermStart(term, '2025-09-03');
      await target.writeSession(const SavedSession(loginId: 'A', displayName: 'A', className: '', cookieJson: 'new-cookie', savedAt: 'new'));
      await target.writeGrades(term.xn, term.xq, 'new', '{"new":true}');
      final currentHead = ScheduleStore().edit(term, [], 'keep-head', '2026-09-24T00:00:00Z');
      await target.insertRevision(currentHead);
      final report = await store.importLegacy(a, target);
      expect(report.imported, greaterThan(205));
      expect(report.skipped, greaterThan(0));
      expect((await target.readSession())!.cookieJson, 'new-cookie');
      expect((await target.terms()).first.key, other.key);
      expect(await target.termStartDate(term.xn, term.xq), '2025-09-03');
      expect((await target.loadTermStore(term)).head(term)?.id, currentHead.id);
      expect(await target.gradesPayload(term.xn, term.xq), '{"new":true}');
      final revisions = await target.revisionSummaries(term).toList();
      expect(revisions, hasLength(100));
      expect((await store.importLegacy(a, target)).alreadyImported, isTrue);
      expect(await target.revisionSummaries(term).length, 100);
      expect((await store.legacyState(b)).available, isFalse);
      final targetB = await store.openAccount(b);
      await expectLater(store.importLegacy(b, targetB), throwsStateError);
      expect(await File(path).readAsBytes(), before);
      await target.close(); await targetB.close(); await store.close();
      await dir.delete(recursive: true);
    });
  }

  test('claim之后失败可同账号恢复，目标提交后index未完成也不会重复', () async {
    final dir = await Directory.systemTemp.createTemp('superxd-interrupt-');
    final legacyPath = '${dir.path}/superxd.db';
    final legacy = await AppDatabase.open(databasePath: legacyPath);
    await legacy.saveTerms([term]);
    await legacy.writeGrades(term.xn, term.xq, 'old', '{}');
    await legacy.close();
    final raw = await openDatabase(legacyPath, singleInstance: false);
    await raw.execute('DROP TABLE account_owner');
    await raw.execute('DROP TABLE legacy_import_marker');
    await raw.setVersion(2);
    await raw.close();
    var store = await AccountStore.open(directory: dir.path);
    var target = await store.openAccount(a);
    final rawTarget = await openDatabase(target.databasePath, singleInstance: false);
    await rawTarget.execute("CREATE TRIGGER fail_import BEFORE INSERT ON grades_cache BEGIN SELECT RAISE(ABORT, 'test interruption'); END");
    await expectLater(store.importLegacy(a, target), throwsA(anything));
    expect(await target.terms(), isEmpty);
    expect((await store.legacyState(a)).resumable, isTrue);
    expect((await store.legacyState(b)).available, isFalse);
    await rawTarget.execute('DROP TRIGGER fail_import'); await rawTarget.close();
    await target.close(); await store.close();
    store = await AccountStore.open(directory: dir.path);
    target = await store.openAccount(a);
    expect((await store.importLegacy(a, target)).alreadyImported, isFalse);
    await target.close(); await store.close();
    final index = await openDatabase('${dir.path}/account_index.db', singleInstance: false);
    await index.update('legacy_claim', {'status': 'claimed'});
    await index.close();
    store = await AccountStore.open(directory: dir.path); target = await store.openAccount(a);
    expect((await store.importLegacy(a, target)).alreadyImported, isTrue);
    expect(await target.terms(), hasLength(1));
    await target.close(); await store.close(); await dir.delete(recursive: true);
  });
}
