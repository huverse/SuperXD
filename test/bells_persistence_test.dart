import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:superxd/edu/kingo_client.dart';
import 'package:superxd/edu/parse_bells.dart';
import 'package:superxd/gateway/kingo_campus_gateway.dart';
import 'package:superxd/local/app_database.dart';
import 'package:superxd/local/schedule_store.dart';

const current = TermRef(xn: '2026', xq: '0', label: '2026-2027第一学期');
const previous = TermRef(xn: '2025', xq: '1', label: '2025-2026第二学期');

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  for (final hasSourceTable in [false, true]) {
    test('v1迁移保留所有数据，来源表已存在=$hasSourceTable', () async {
      final dir = await Directory.systemTemp.createTemp('superxd-migration-');
      final file = '${dir.path}/app.db';
      var db = await AppDatabase.open(databasePath: file);
      await db.writeSession(const SavedSession(loginId: 'test', displayName: '测试', className: '', cookieJson: '{"cookies":{}}', savedAt: '2026-09-24T00:00:00Z'));
      await db.saveTerms([current, previous], currentXn: current.xn, currentXq: current.xq);
      await db.setTermStart(current, '2026-08-31');
      final store = ScheduleStore();
      final revision = store.edit(current, [], '本地版本', '2026-09-24T00:00:00Z');
      await db.insertRevision(revision);
      await db.writeGrades(current.xn, current.xq, 'stamp', '{"summary":null}');
      await _writeBells(db, previous);
      if (hasSourceTable) await db.setBellsSource(targetXn: current.xn, targetXq: current.xq, sourceXn: previous.xn, sourceXq: previous.xq);
      await db.close();
      final old = await openDatabase(file);
      if (!hasSourceTable) await old.execute('DROP TABLE term_bells_source');
      await old.execute('DROP INDEX schedule_revision_term_created');
      await old.setVersion(1);
      await old.close();

      db = await AppDatabase.open(databasePath: file);
      expect((await db.readSession())?.loginId, 'test');
      expect(await db.termStartDate(current.xn, current.xq), '2026-08-31');
      expect((await db.loadTermStore(current)).head(current)?.id, revision.id);
      expect(await db.gradesPayload(current.xn, current.xq), '{"summary":null}');
      expect((await db.bellsRow(previous.xn, previous.xq))?['empty'], 0);
      expect((await db.bellsSource(current.xn, current.xq))?.key, hasSourceTable ? previous.key : null);
      await db.close();
      await dir.delete(recursive: true);
    });
  }

  test('采用重启后纯本地读取，空/无效来源不覆盖绑定，恢复本学期不跟随引用链', () async {
    final dir = await Directory.systemTemp.createTemp('superxd-bells-');
    final file = '${dir.path}/app.db';
    var db = await AppDatabase.open(databasePath: file);
    await db.saveTerms([current, previous], currentXn: current.xn, currentXq: current.xq);
    await _writeBells(db, previous);
    await db.writeBells(xn: current.xn, xq: current.xq, fetchedAt: 'stamp', empty: true, message: '未设置', periodsJson: '[]');
    var gateway = KingoCampusGateway(database: db, client: _NoNetwork());
    expect((await gateway.useBellsSource(current, previous)).ok, isTrue);
    expect((await db.bellsRow(current.xn, current.xq))?['periods_json'], '[]');
    await db.close();

    db = await AppDatabase.open(databasePath: file);
    gateway = KingoCampusGateway(database: db, client: _NoNetwork());
    final effective = await gateway.readBells(current);
    expect(effective.source, 'local');
    expect(effective.data?.term.key, current.key);
    expect(effective.data?.sourceTerm?.key, previous.key);
    expect(effective.data?.periods.first.start, '08:00');
    expect((await gateway.useBellsSource(current, current)).error?.code, 'BELLS_SOURCE_INVALID');
    expect((await gateway.readBellsSource(current)).data?.key, previous.key);
    const invalid = TermRef(xn: '2024', xq: '0');
    await db.writeBells(xn: invalid.xn, xq: invalid.xq, fetchedAt: 'stamp', empty: false, message: '', periodsJson: '[{"period":1,"start":"99:00","end":"10:00"}]');
    expect((await gateway.useBellsSource(current, invalid)).ok, isFalse);
    expect((await gateway.readBellsSource(current)).data?.key, previous.key);

    final syncing = KingoCampusGateway(database: db, client: _BellsClient());
    expect((await syncing.syncBells(current)).ok, isTrue);
    expect((await syncing.readBellsSource(current)).data?.key, previous.key);
    expect((await syncing.readBells(current)).data?.periods.first.start, '08:00');
    expect((await syncing.useBellsSource(current, current)).ok, isTrue);
    expect((await syncing.readBellsSource(current)).data, isNull);
    expect((await syncing.readBells(current)).data?.periods.first.start, '09:00');
    await db.close();
    await dir.delete(recursive: true);
  });
}

Future<void> _writeBells(AppDatabase db, TermRef term) => db.writeBells(
  xn: term.xn, xq: term.xq, fetchedAt: '2026-09-24T00:00:00Z', empty: false, message: '',
  periodsJson: jsonEncode([{'period': 1, 'dayPart': '上午', 'dayPartCode': 'morning', 'start': '08:00', 'end': '08:45'}]),
);

class _NoNetwork extends KingoClient {
  @override
  Future<ParsedBells> fetchBells({required String xn, required String xq}) => throw StateError('不应联网');
}

class _BellsClient extends _NoNetwork {
  @override
  Future<ParsedBells> fetchBells({required String xn, required String xq}) async => const ParsedBells(
    empty: false, message: '', termLabel: '当前作息',
    periods: [ParsedBell(period: 1, dayPart: '上午', dayPartCode: 'morning', start: '09:00', end: '09:45')],
  );
}
