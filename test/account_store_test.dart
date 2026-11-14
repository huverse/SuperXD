import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:superxd/domain/account.dart';
import 'package:superxd/local/account_store.dart';
import 'package:superxd/local/app_database.dart';
import 'package:superxd/domain/schedule_store.dart';

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
    test('显式 v$version 库升到当前版本保留原数据且不自动写 owner，补建提醒设置与自动同步的表', () async {
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
      await old.execute('DROP TABLE reminder_setting');
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
      expect(await upgraded.getVersion(), 8);
      expect(await upgraded.query('account_owner'), isEmpty);
      expect(await upgraded.query('legacy_import_marker'), isEmpty);
      expect(await upgraded.query('reminder_setting'), isEmpty);
      expect(await upgraded.query('schedule_sync_hold'), isEmpty);
      expect(await upgraded.query('auto_sync'), isEmpty);
      await upgraded.close();
      await directory.delete(recursive: true);
    });
  }

  // 人工决策见 AccountStore.open。安卓上新引擎接回旧引擎留下的那条连接、回滚停在中间的事务，只发生在原生层（ffi 不报告接回状态，测不到回滚）：
  // 这里测单实例的效果（同一路径共用一条连接），再守住回滚开关与前台、后台各自的接线；接回与回滚在模拟器上用探针验。
  test('前台接管旧引擎遗留的连接：账号索引与账号库都用单实例并回滚停在中间的事务；后台照旧用独立连接', () async {
    final directory = await Directory.systemTemp.createTemp('account-reclaim-');
    addTearDown(() => directory.delete(recursive: true));
    Future<bool> usable(Future<Object?> Function() read) async {
      try {
        await read();
        return true;
      } on DatabaseException {
        return false;
      }
    }
    for (final reclaim in [true, false]) {
      final first = await AccountStore.open(directory: directory.path, reclaim: reclaim);
      await first.activate(_accountA);
      final account = await first.openAccount(_accountA);
      final second = await AccountStore.open(directory: directory.path, reclaim: reclaim);
      await (await second.openAccount(_accountA)).close();
      await second.close();
      expect(await usable(first.currentIdentity), !reclaim, reason: '账号索引 reclaim=$reclaim');
      expect(await usable(() => account.terms()), !reclaim, reason: '账号库 reclaim=$reclaim');
      if (!reclaim) {
        await account.close();
        await first.close();
      }
    }
    for (final file in ['lib/local/account_store.dart', 'lib/local/app_database.dart']) {
      expect(File(file).readAsStringSync(), contains('singleInstance: reclaim, rollbackActiveTransactionOnOpen: reclaim'), reason: file);
    }
    expect(File('lib/main.dart').readAsStringSync(), contains('AccountStore.open(reclaim: true)'));
    expect(File('lib/app_background_sync.dart').readAsStringSync(), allOf(contains('AccountStore.open()'), isNot(contains('reclaim'))));
  });

  // 其余前台库同样单实例并回滚遗留的事务（sqflite 默认只在调试包回滚）：lib 里打开库的文件都要显式写回滚开关。
  test('前台的其余本机库都显式回滚接回连接上停在中间的事务', () {
    final opening = [
      for (final file in Directory('lib').listSync(recursive: true).whereType<File>().where((file) => file.path.endsWith('.dart')))
        if (RegExp(r'\bopenDatabase\(').hasMatch(file.readAsStringSync())) file.path,
    ];
    expect(opening, containsAll(['lib/local/display_settings.dart', 'lib/social/social_store.dart', 'lib/toolbox/toolbox_store.dart', 'lib/toolbox/short_video/short_video_store.dart', 'lib/toolbox/chaoxing/chaoxing_store.dart']));
    for (final file in opening) {
      final source = File(file).readAsStringSync();
      // AppDatabase.open 只给测试与工具（内存库、指定路径），账号库走 openForAccount。
      final plain = RegExp(r'(?<!databaseFactory\.)\bopenDatabase\(').allMatches(source).length;
      expect(plain, file == 'lib/local/app_database.dart' ? 1 : 0, reason: '$file 要用 databaseFactory.openDatabase 并写回滚开关');
      expect(source, contains('rollbackActiveTransactionOnOpen: '), reason: file);
    }
  });

  // 人工决策见 AccountStore.release：后台那份引擎被叫停时收回自己开的连接，release 依赖「关连接时进行中的事务下一句报已关闭、整体回滚，然后放开写锁」。
  test('关掉连接时进行中的写事务下一句报已关闭并整体回滚，再关掉、放开写锁', () async {
    final directory = await Directory.systemTemp.createTemp('account-release-');
    addTearDown(() => directory.delete(recursive: true));
    final file = path.join(directory.path, 'lock.db');
    final first = await databaseFactory.openDatabase(file, options: OpenDatabaseOptions(singleInstance: false, version: 1, onCreate: (db, _) => db.execute('CREATE TABLE item (value INTEGER)')));
    final began = Completer<void>(), hold = Completer<void>();
    final pending = first.transaction((transaction) async {
      await transaction.insert('item', {'value': 1});
      began.complete();
      await hold.future;
      await transaction.insert('item', {'value': 2});
    });
    await began.future;
    var closed = false;
    final closing = first.close().then((_) => closed = true);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(closed, isFalse);
    hold.complete();
    await expectLater(pending, throwsA(isA<DatabaseException>()));
    await closing;
    await expectLater(() => first.query('item'), throwsA(isA<DatabaseException>()));
    final second = await databaseFactory.openDatabase(file, options: OpenDatabaseOptions(singleInstance: false));
    await second.execute('BEGIN IMMEDIATE');
    await second.execute('COMMIT');
    expect(await second.query('item'), isEmpty);
    await second.close();
  });

  test('后台那份收回连接：账号索引与开过的账号库都关掉，重复收回不报错，之后照常能打开', () async {
    final directory = await Directory.systemTemp.createTemp('account-release-');
    addTearDown(() => directory.delete(recursive: true));
    Future<bool> usable(Future<Object?> Function() read) async {
      try {
        await read();
        return true;
      } on DatabaseException {
        return false;
      }
    }

    final store = await AccountStore.open(directory: directory.path);
    await store.activate(_accountA);
    final account = await store.openAccount(_accountA);
    await store.release();
    expect(await usable(store.currentIdentity), isFalse);
    expect(await usable(() => account.terms()), isFalse);
    await store.release();
    await account.close();
    await store.close();
    final again = await AccountStore.open(directory: directory.path);
    expect((await again.currentIdentity())?.loginId, _accountA.loginId);
    await (await again.openAccount(_accountA)).close();
    await again.close();
  });
}
