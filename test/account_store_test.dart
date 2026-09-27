import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:superxd/gateway/account_access.dart';
import 'package:superxd/local/account_store.dart';
import 'package:superxd/local/app_database.dart';
import 'package:superxd/local/schedule_store.dart';

const _accountA = AccountIdentity(source: 'https://campus.example.edu/base', loginId: 'student-a');
const _accountB = AccountIdentity(source: 'https://campus.example.edu/base', loginId: 'student-b');
const _term = TermRef(xn: '2026', xq: '0', label: '当前学期');

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('身份键规范 URL 但保留 base path、scheme 和教务确认的账号', () async {
    final directory = await Directory.systemTemp.createTemp('account-key-');
    final store = await AccountStore.open(directory: directory.path);
    try {
      const alternate = AccountIdentity(source: ' HTTPS://CAMPUS.EXAMPLE.EDU:443/base/./ ', loginId: ' student-a ');
      expect(store.keyOf(alternate), store.keyOf(_accountA));
      expect(store.keyOf(_accountA), sha256.convert(utf8.encode(jsonEncode([_accountA.source, _accountA.loginId]))).toString());
      expect(store.keyOf(const AccountIdentity(source: 'https://campus.example.edu/other', loginId: 'student-a')), isNot(store.keyOf(_accountA)));
      expect(store.keyOf(const AccountIdentity(source: 'http://campus.example.edu/base', loginId: 'student-a')), isNot(store.keyOf(_accountA)));
      expect(store.keyOf(_accountB), isNot(store.keyOf(_accountA)));
      expect(() => store.keyOf(const AccountIdentity(source: 'https://campus.example.edu', loginId: ' ')), throwsArgumentError);
      expect(() => store.keyOf(const AccountIdentity(source: 'file:///tmp/campus', loginId: 'student-a')), throwsArgumentError);
      expect(() => store.keyOf(const AccountIdentity(source: 'https://campus.example.edu?token=x', loginId: 'student-a')), throwsArgumentError);
    } finally {
      await store.close();
      await directory.delete(recursive: true);
    }
  });

  test('A/B 数据物理隔离、关闭重开恢复身份、登出仅清活动指针', () async {
    final directory = await Directory.systemTemp.createTemp('account-isolation-');
    var store = await AccountStore.open(directory: directory.path);
    final accountA = await store.openAccount(_accountA);
    await accountA.saveTerms([_term], currentXn: _term.xn, currentXq: _term.xq);
    await accountA.setTermStart(_term, '2026-08-31');
    await accountA.writeGrades(_term.xn, _term.xq, 'stamp-a', '{"owner":"a"}');
    await accountA.writeSession(const SavedSession(loginId: 'student-a', displayName: '同名', className: '班级', cookieJson: '{"secret":"a"}', savedAt: 'stamp-a'));
    await accountA.clearSession();
    await store.activate(_accountA, displayName: '同名');
    await accountA.close();
    await store.close();

    store = await AccountStore.open(directory: directory.path);
    expect((await store.currentIdentity())?.loginId, 'student-a');
    final reopenedA = await store.openAccount(_accountA);
    expect(await reopenedA.readSession(), isNull);
    expect(await reopenedA.gradesPayload(_term.xn, _term.xq), '{"owner":"a"}');
    await reopenedA.close();
    final accountB = await store.openAccount(_accountB);
    expect(await accountB.terms(), isEmpty);
    expect(await accountB.gradesPayload(_term.xn, _term.xq), isNull);
    expect(await accountB.readSession(), isNull);
    await accountB.writeGrades(_term.xn, _term.xq, 'stamp-b', '{"owner":"b"}');
    await store.activate(_accountB, displayName: '同名');
    await accountB.close();
    await store.clearCurrent();
    expect(await store.currentIdentity(), isNull);
    await store.close();

    store = await AccountStore.open(directory: directory.path);
    expect(await store.currentIdentity(), isNull);
    final finalA = await store.openAccount(_accountA);
    final finalB = await store.openAccount(_accountB);
    expect(await finalA.gradesPayload(_term.xn, _term.xq), '{"owner":"a"}');
    expect(await finalB.gradesPayload(_term.xn, _term.xq), '{"owner":"b"}');
    expect(await finalA.termStartDate(_term.xn, _term.xq), '2026-08-31');
    await finalA.close();
    await finalB.close();
    await store.close();
    final index = await openReadOnlyDatabase('${directory.path}/account_index.db', singleInstance: false);
    expect((await index.rawQuery("SELECT name FROM sqlite_master WHERE type='table' AND name != 'android_metadata' ORDER BY name")).map((row) => row['name']), ['account', 'active_account', 'legacy_claim']);
    await index.close();
    await directory.delete(recursive: true);
  });

  test('owner 独立于 session，拒绝错账号文件且不认领无 owner 的已有库', () async {
    final directory = await Directory.systemTemp.createTemp('account-owner-');
    final store = await AccountStore.open(directory: directory.path);
    final accountA = await store.openAccount(_accountA);
    await accountA.close();
    final aPath = '${directory.path}/accounts/${store.keyOf(_accountA)}.db';
    final bPath = '${directory.path}/accounts/${store.keyOf(_accountB)}.db';
    await File(aPath).copy(bPath);
    await expectLater(store.openAccount(_accountB), throwsStateError);
    await File(bPath).delete();
    final unowned = await AppDatabase.open(databasePath: bPath);
    await unowned.writeGrades('2026', '0', 'stamp', 'foreign-data');
    await unowned.close();
    await expectLater(store.openAccount(_accountB), throwsStateError);
    await store.close();
    await directory.delete(recursive: true);
  });

  test('Android只有系统metadata的新库可以创建账号owner', () async {
    final directory = await Directory.systemTemp.createTemp('android-metadata-');
    final store = await AccountStore.open(directory: directory.path);
    final accounts = await Directory('${directory.path}/accounts').create();
    final file = '${accounts.path}/${store.keyOf(_accountA)}.db';
    final raw = await openDatabase(file, singleInstance: false);
    await raw.execute('CREATE TABLE android_metadata (locale TEXT)');
    await raw.close();
    final db = await store.openAccount(_accountA);
    await db.verifyOwner(_accountA);
    expect(await db.terms(), isEmpty);
    await db.close(); await store.close(); await directory.delete(recursive: true);
  });

  test('启动只开索引，不读取或升级旧库，默认 AppDatabase 路径被禁止', () async {
    final directory = await Directory.systemTemp.createTemp('account-legacy-untouched-');
    final legacy = File('${directory.path}/superxd.db');
    await legacy.writeAsString('not-a-database');
    final before = await legacy.readAsBytes();
    final store = await AccountStore.open(directory: directory.path);
    expect(await store.currentIdentity(), isNull);
    expect((await store.legacyState(_accountA)).available, isTrue);
    final account = await store.openAccount(_accountA);
    expect(await account.terms(), isEmpty);
    await account.close();
    await expectLater(AppDatabase.open(), throwsArgumentError);
    expect(await legacy.readAsBytes(), before);
    await store.close();
    await directory.delete(recursive: true);
  });

  for (final version in [1, 2]) {
    test('显式 v$version 库升级 v5 保留原数据且不自动写 owner', () async {
      final directory = await Directory.systemTemp.createTemp('account-version-');
      final file = '${directory.path}/test.db';
      var database = await AppDatabase.open(databasePath: file);
      await database.writeSession(const SavedSession(loginId: 'legacy', displayName: '', className: '', cookieJson: 'secret', savedAt: 'stamp'));
      await database.saveTerms([_term]);
      await database.setTermStart(_term, '2026-08-31');
      await database.close();
      final old = await openDatabase(file, singleInstance: false);
      await old.execute('DROP TABLE account_owner');
      await old.execute('DROP TABLE legacy_import_marker');
      if (version == 1) {
        await old.execute('DROP TABLE term_bells_source');
        await old.execute('DROP INDEX schedule_revision_term_created');
      }
      await old.setVersion(version);
      await old.close();
      database = await AppDatabase.open(databasePath: file);
      expect((await database.readSession())?.cookieJson, 'secret');
      expect(await database.termStartDate(_term.xn, _term.xq), '2026-08-31');
      await database.close();
      final upgraded = await openReadOnlyDatabase(file, singleInstance: false);
      expect(await upgraded.getVersion(), 5);
      expect(await upgraded.query('account_owner'), isEmpty);
      expect(await upgraded.query('legacy_import_marker'), isEmpty);
      await upgraded.close();
      await directory.delete(recursive: true);
    });
  }
}
