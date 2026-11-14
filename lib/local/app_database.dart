import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'package:superxd/domain/account.dart';
import 'package:superxd/domain/auto_sync.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/local/legacy_import.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/domain/schedule_edit.dart';

class SavedSession {
  const SavedSession({
    required this.loginId,
    required this.displayName,
    required this.className,
    required this.cookieJson,
    required this.savedAt,
  });

  final String loginId;
  final String displayName;
  final String className;
  final String cookieJson;
  final String savedAt;
}

class AppDatabase {
  AppDatabase(this._db);

  final Database _db;

  static Future<AppDatabase> open({String? databasePath}) async {
    if (databasePath == null) throw ArgumentError('必须显式指定数据库路径；账号数据库请使用 AccountStore');
    final db = await openDatabase(databasePath, version: 8, onConfigure: _configure, onCreate: _create, onUpgrade: _upgrade);
    return AppDatabase(db);
  }

  // reclaim：前台接管旧引擎遗留的连接（人工决策见 AccountStore.open）。
  static Future<AppDatabase> openForAccount({required String databasePath, required AccountIdentity identity, bool reclaim = false}) async {
    final db = await databaseFactory.openDatabase(databasePath, options: OpenDatabaseOptions(version: 8, singleInstance: reclaim, rollbackActiveTransactionOnOpen: reclaim,
      onConfigure: (db) async {
        await _configure(db);
        // Android 会先创建 android_metadata；它不是旧业务数据，不能阻止新账号库初始化。
        final tables = await db.rawQuery("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name != 'android_metadata' LIMIT 1");
        if (tables.isNotEmpty) await _verifyOwner(db, identity);
      },
      onCreate: (db, version) async {
        await _create(db, version);
        await db.insert('account_owner', {'id': 1, 'source': identity.source, 'login_id': identity.loginId});
      },
      onUpgrade: _upgrade,
      onOpen: (db) => _verifyOwner(db, identity),
    ));
    return AppDatabase(db);
  }

  static Future<AppDatabase> openMemory() => open(databasePath: inMemoryDatabasePath);

  String get databasePath => _db.path;

  Future<void> close() => _db.close();

  Future<void> verifyOwner(AccountIdentity identity) => _verifyOwner(_db, identity);

  static Future<void> _verifyOwner(DatabaseExecutor db, AccountIdentity identity) async {
    final tables = await db.rawQuery("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'account_owner' LIMIT 1");
    if (tables.isEmpty) throw StateError('账号数据库缺少 owner，不能自动归属');
    final rows = await db.query('account_owner', where: 'id = 1', limit: 1);
    if (rows.isEmpty || rows.single['source'] != identity.source || rows.single['login_id'] != identity.loginId) {
      throw StateError('账号数据库 owner 与当前身份不匹配');
    }
  }

  Future<LegacyImportReport?> legacyImportReport(String legacyKey) async {
    final rows = await _db.query('legacy_import_marker', where: 'legacy_key = ?', whereArgs: [legacyKey], limit: 1);
    if (rows.isEmpty) return null;
    return LegacyImportReport(imported: rows.single['imported'] as int, skipped: rows.single['skipped'] as int, alreadyImported: true);
  }

  Future<LegacyImportReport> importLegacyRows(DatabaseExecutor legacy, {required String legacyKey, required AccountIdentity identity}) {
    return _db.transaction((transaction) async {
      await _verifyOwner(transaction, identity);
      final report = await importLegacyDatabase(legacy: legacy, target: transaction, legacyKey: legacyKey);
      await _pruneAllRevisions(transaction);
      return report;
    });
  }

  static Future<void> _upgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 5) {
      final columns = await db.rawQuery('PRAGMA table_info(grades_cache)');
      if (columns.isNotEmpty && !columns.any((row) => row['name'] == 'summary_json')) await db.execute('ALTER TABLE grades_cache ADD COLUMN summary_json TEXT');
    }
    if (oldVersion < 2) await _createBellsSource(db);
    if (oldVersion < 3) await _createAccountMetadata(db);
    if (oldVersion < 4) {
      final columns = await db.rawQuery('PRAGMA table_info(schedule_revision)');
      if (!columns.any((row) => row['name'] == 'sequence')) {
        await db.execute('ALTER TABLE schedule_revision ADD COLUMN sequence INTEGER NOT NULL DEFAULT 0');
        await db.execute("ALTER TABLE schedule_revision ADD COLUMN operation TEXT NOT NULL DEFAULT 'edit'");
        await db.execute('ALTER TABLE schedule_revision ADD COLUMN restored_from_id TEXT');
        await db.execute("UPDATE schedule_revision SET sequence = rowid, operation = CASE WHEN source = 'edu' THEN 'sync' ELSE 'edit' END");
      }
      await _revisionIndexes(db);
      await _pruneAllRevisions(db);
    }
    if (oldVersion < 6) await _createReminderSetting(db);
    if (oldVersion < 7) {
      final columns = await db.rawQuery('PRAGMA table_info(reminder_setting)');
      if (!columns.any((row) => row['name'] == 'live')) await db.execute('ALTER TABLE reminder_setting ADD COLUMN live INTEGER NOT NULL DEFAULT 0');
    }
    if (oldVersion < 8) await _createAutoSync(db);
  }

  static Future<void> _revisionIndexes(DatabaseExecutor db) async {
    await db.execute('CREATE INDEX IF NOT EXISTS schedule_revision_sequence ON schedule_revision (sequence)');
    await db.execute('CREATE UNIQUE INDEX IF NOT EXISTS schedule_revision_term_sequence ON schedule_revision (xn, xq, sequence)');
    await db.execute('CREATE INDEX IF NOT EXISTS schedule_revision_term_source_sequence ON schedule_revision (xn, xq, source, sequence)');
  }

  static Future<void> _pruneAllRevisions(DatabaseExecutor db) async {
    String? afterYear;
    String? afterTerm;
    while (true) {
      final terms = await db.query('schedule_revision', columns: ['xn', 'xq'], distinct: true,
        where: afterYear == null ? null : '(xn, xq) > (?, ?)',
        whereArgs: afterYear == null ? null : [afterYear, afterTerm], orderBy: 'xn, xq', limit: 100);
      for (final term in terms) { await _pruneRevisions(db, term['xn'] as String, term['xq'] as String); }
      if (terms.length < 100) return;
      afterYear = terms.last['xn'] as String; afterTerm = terms.last['xq'] as String;
    }
  }

  // [人工决策-2026-09-25 00:19:22] 每学期最多100版，当前版和最近教务基线计入并受保护；仅清理当前账号的目标历史。
  static Future<void> _pruneRevisions(DatabaseExecutor db, String year, String term) async {
    final head = await db.query('schedule_head', columns: ['revision_id'], where: 'xn = ? AND xq = ?', whereArgs: [year, term], limit: 1);
    final edu = await db.query('schedule_revision', columns: ['id'], where: "xn = ? AND xq = ? AND source = 'edu'", whereArgs: [year, term], orderBy: 'sequence DESC', limit: 1);
    final protected = <Object?>{?head.firstOrNull?['revision_id'], ?edu.firstOrNull?['id']};
    final latest = await db.query('schedule_revision', columns: ['id'], where: 'xn = ? AND xq = ?', whereArgs: [year, term], orderBy: 'sequence DESC', limit: scheduleRevisionLimit);
    final keep = {...protected, ...latest.map((row) => row['id']).where((id) => !protected.contains(id)).take(scheduleRevisionLimit - protected.length)};
    if (keep.isEmpty) return;
    final exclusions = List.filled(keep.length, '?').join(',');
    while (true) {
      final obsolete = await db.query('schedule_revision', columns: ['id'], where: 'xn = ? AND xq = ? AND id NOT IN ($exclusions)', whereArgs: [year, term, ...keep], orderBy: 'sequence', limit: 200);
      if (obsolete.isEmpty) return;
      await db.delete('schedule_revision', where: 'id IN (${List.filled(obsolete.length, '?').join(',')})', whereArgs: obsolete.map((row) => row['id']).toList());
      if (obsolete.length < 200) return;
    }
  }

  static Future<void> _createAccountMetadata(Database db) async {
    await db.execute('''
CREATE TABLE IF NOT EXISTS account_owner (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  source TEXT NOT NULL,
  login_id TEXT NOT NULL
)''');
    await db.execute('''
CREATE TABLE IF NOT EXISTS legacy_import_marker (
  legacy_key TEXT PRIMARY KEY,
  imported INTEGER NOT NULL,
  skipped INTEGER NOT NULL
)''');
  }

  static Future<void> _createBellsSource(Database db) async {
    await db.execute('''
CREATE TABLE IF NOT EXISTS term_bells_source (
  target_xn TEXT NOT NULL,
  target_xq TEXT NOT NULL,
  source_xn TEXT NOT NULL,
  source_xq TEXT NOT NULL,
  PRIMARY KEY (target_xn, target_xq)
)''');
    await db.execute('CREATE INDEX IF NOT EXISTS schedule_revision_term_created ON schedule_revision (xn, xq, created_at, id)');
  }

  static Future<void> _configure(Database db) async {
    await db.execute('PRAGMA foreign_keys = ON');
  }

  static Future<void> _create(Database db, int version) async {
    await db.execute('''
CREATE TABLE session (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  login_id TEXT NOT NULL,
  display_name TEXT NOT NULL DEFAULT '',
  class_name TEXT NOT NULL DEFAULT '',
  cookie_json TEXT NOT NULL,
  saved_at TEXT NOT NULL
)''');
    await db.execute('''
CREATE TABLE term (
  xn TEXT NOT NULL,
  xq TEXT NOT NULL,
  label TEXT NOT NULL,
  is_current INTEGER NOT NULL DEFAULT 0,
  start_date TEXT,
  PRIMARY KEY (xn, xq)
)''');
    await db.execute('''
CREATE TABLE schedule_revision (
  id TEXT PRIMARY KEY,
  xn TEXT NOT NULL,
  xq TEXT NOT NULL,
  source TEXT NOT NULL CHECK (source IN ('edu', 'user')),
  parent_id TEXT,
  created_at TEXT NOT NULL,
  summary TEXT NOT NULL,
  sequence INTEGER NOT NULL,
  operation TEXT NOT NULL DEFAULT 'edit',
  restored_from_id TEXT,
  courses_json TEXT NOT NULL
)''');
    await db.execute('''
CREATE TABLE schedule_head (
  xn TEXT NOT NULL,
  xq TEXT NOT NULL,
  revision_id TEXT NOT NULL,
  PRIMARY KEY (xn, xq),
  FOREIGN KEY (revision_id) REFERENCES schedule_revision (id)
)''');
    await db.execute('''
CREATE TABLE grades_cache (
  xn TEXT NOT NULL,
  xq TEXT NOT NULL,
  fetched_at TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  summary_json TEXT,
  PRIMARY KEY (xn, xq)
)''');
    await db.execute('''
CREATE TABLE bells_cache (
  xn TEXT NOT NULL,
  xq TEXT NOT NULL,
  fetched_at TEXT NOT NULL,
  empty INTEGER NOT NULL,
  message TEXT NOT NULL DEFAULT '',
  periods_json TEXT NOT NULL,
  PRIMARY KEY (xn, xq)
)''');
    await _createBellsSource(db);
    await _createAccountMetadata(db);
    await _revisionIndexes(db);
    await _createReminderSetting(db);
    await _createAutoSync(db);
  }

  // 自动同步（人工决策见 domain/auto_sync.dart，v8 新增）：schedule_sync_hold 是和本地改过的课表冲突、等用户来选的教务课表，
  // 每学期最多一行，教务课表落成新版本时删掉；auto_sync 是设置与上次结果，只有一行。两张表的行数都有界。
  static Future<void> _createAutoSync(Database db) async {
    await db.execute('''
CREATE TABLE IF NOT EXISTS schedule_sync_hold (
  xn TEXT NOT NULL,
  xq TEXT NOT NULL,
  courses_json TEXT NOT NULL,
  fetched_at TEXT NOT NULL,
  dismissed INTEGER NOT NULL,
  PRIMARY KEY (xn, xq)
)''');
    await db.execute('''
CREATE TABLE IF NOT EXISTS auto_sync (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  enabled INTEGER NOT NULL,
  interval_minutes INTEGER NOT NULL,
  years_json TEXT,
  contents_json TEXT NOT NULL,
  last_attempt_at TEXT,
  last_success_at TEXT,
  last_state TEXT,
  last_message TEXT NOT NULL DEFAULT '',
  updated_at TEXT NOT NULL
)''');
  }

  // 课前提醒设置：每学期一行，行数随学期数有界。
  static Future<void> _createReminderSetting(Database db) async {
    await db.execute('''
CREATE TABLE IF NOT EXISTS reminder_setting (
  xn TEXT NOT NULL,
  xq TEXT NOT NULL,
  enabled INTEGER NOT NULL,
  lead_minutes INTEGER NOT NULL,
  updated_at TEXT NOT NULL,
  live INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (xn, xq)
)''');
  }

  Future<ReminderSetting?> readReminderSetting(TermRef term) async {
    final rows = await _db.query('reminder_setting', where: 'xn = ? AND xq = ?', whereArgs: [term.xn, term.xq], limit: 1);
    final row = rows.firstOrNull;
    return row == null ? null : ReminderSetting(enabled: row['enabled'] == 1, leadMinutes: row['lead_minutes'] as int, live: row['live'] == 1);
  }

  Future<void> saveReminderSetting(TermRef term, ReminderSetting setting, {required String now}) => _db.insert(
    'reminder_setting',
    {'xn': term.xn, 'xq': term.xq, 'enabled': setting.enabled ? 1 : 0, 'lead_minutes': setting.leadMinutes, 'live': setting.live ? 1 : 0, 'updated_at': now},
    conflictAlgorithm: ConflictAlgorithm.replace,
  );

  Future<SavedSession?> readSession() async {
    final rows = await _db.query('session', where: 'id = 1');
    if (rows.isEmpty) return null;
    final row = rows.single;
    return SavedSession(
      loginId: row['login_id'] as String,
      displayName: row['display_name'] as String,
      className: row['class_name'] as String,
      cookieJson: row['cookie_json'] as String,
      savedAt: row['saved_at'] as String,
    );
  }

  Future<void> writeSession(SavedSession session) async {
    await _db.insert('session', {
      'id': 1,
      'login_id': session.loginId,
      'display_name': session.displayName,
      'class_name': session.className,
      'cookie_json': session.cookieJson,
      'saved_at': session.savedAt,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> updateSessionNames(String displayName, String className) async {
    await _db.update('session', {
      'display_name': displayName,
      'class_name': className,
    }, where: 'id = 1');
  }

  Future<void> clearSession() async {
    await _db.delete('session', where: 'id = 1');
  }

  Future<List<TermRef>> terms() async {
    final rows = await _db.query('term', orderBy: 'is_current DESC, xn DESC, xq DESC');
    return rows
        .map((row) => TermRef(xn: row['xn'] as String, xq: row['xq'] as String, label: row['label'] as String))
        .toList();
  }

  Future<void> saveTerms(List<TermRef> terms, {String? currentXn, String? currentXq}) async {
    final batch = _db.batch();
    final hasCurrent = currentXn != null && currentXq != null;
    if (hasCurrent) batch.update('term', {'is_current': 0}, where: 'is_current = 1');
    for (final term in terms) {
      final current = term.xn == currentXn && term.xq == currentXq;
      batch.rawInsert(
        '''
INSERT INTO term (xn, xq, label, is_current)
VALUES (?, ?, ?, ?)
ON CONFLICT(xn, xq) DO UPDATE SET
  label = CASE WHEN excluded.label = '' THEN term.label ELSE excluded.label END,
  is_current = CASE WHEN ? THEN excluded.is_current ELSE term.is_current END
''',
        [term.xn, term.xq, term.label, current ? 1 : 0, hasCurrent ? 1 : 0],
      );
    }
    await batch.commit(noResult: true);
  }

  Future<void> setTermStart(TermRef term, String date) async {
    await _db.rawInsert(
      '''
INSERT INTO term (xn, xq, label, is_current, start_date)
VALUES (?, ?, ?, 0, ?)
ON CONFLICT(xn, xq) DO UPDATE SET
  label = CASE WHEN excluded.label = '' THEN term.label ELSE excluded.label END,
  start_date = excluded.start_date
''',
      [term.xn, term.xq, term.label, date],
    );
  }

  Future<ScheduleStore> loadTermStore(TermRef term, {String? revisionId}) => _db.transaction((transaction) => _loadTermStore(transaction, term, revisionId: revisionId));

  Future<ScheduleStore> _loadTermStore(DatabaseExecutor transaction, TermRef term, {String? revisionId}) async {
      final termRows = await transaction.query('term', where: 'xn = ? AND xq = ?', whereArgs: [term.xn, term.xq], limit: 1);
      final headRows = await transaction.query('schedule_head', where: 'xn = ? AND xq = ?', whereArgs: [term.xn, term.xq], limit: 1);
      final headId = headRows.firstOrNull?['revision_id'] as String?;
      final ids = {?headId, ?revisionId};
      final rows = ids.isEmpty
          ? <Map<String, Object?>>[]
          : await transaction.query('schedule_revision', where: 'id IN (${List.filled(ids.length, '?').join(',')}) AND xn = ? AND xq = ?', whereArgs: [...ids, term.xn, term.xq], limit: ids.length);
      final start = termRows.firstOrNull?['start_date'] as String?;
      final savedTerm = termRows.isEmpty ? term : TermRef(xn: term.xn, xq: term.xq, label: termRows.single['label'] as String);
      return ScheduleStore()..load(
        revisions: rows.map(_revisionOf).toList(),
        heads: {term.key: ?headId},
        termStarts: {if (start != null && start.isNotEmpty) term.key: start},
        terms: {term.key: savedTerm},
      );
  }

  Future<String?> headRevisionId(TermRef term) async {
    final rows = await _db.query('schedule_head', columns: ['revision_id'], where: 'xn = ? AND xq = ?', whereArgs: [term.xn, term.xq], limit: 1);
    return rows.firstOrNull?['revision_id'] as String?;
  }

  Future<List<Map<String, Object?>>> revisionPage(TermRef term, {int? beforeSequence, int limit = 20}) => _db.query('schedule_revision',
    columns: ['id', 'source', 'created_at', 'summary', 'sequence', 'operation', 'restored_from_id'],
    where: 'xn = ? AND xq = ?${beforeSequence == null ? '' : ' AND sequence < ?'}',
    whereArgs: [term.xn, term.xq, ?beforeSequence], orderBy: 'sequence DESC', limit: limit.clamp(1, 100));

  Future<ScheduleRevision?> readRevision(TermRef term, String id) async {
    final rows = await _db.query('schedule_revision', where: 'id = ? AND xn = ? AND xq = ?', whereArgs: [id, term.xn, term.xq], limit: 1);
    return rows.isEmpty ? null : _revisionOf(rows.single);
  }

  // 所有写入的读取、冲突判断、快照和head更新均在同一事务内，不能仅依赖页面锁。
  Future<ScheduleRevision> saveSchedule(TermRef term, List<CourseRecord> courses, String summary, {required String? expectedRevisionId, required String now}) => _db.transaction((transaction) async {
    final store = await _loadTermStore(transaction, term);
    if (store.head(term)?.id != expectedRevisionId) throw const RevisionConflict();
    final normalized = normalizeSchedule(courses);
    validateSchedule(normalized);
    final row = store.edit(term, normalized, summary, now);
    return row.id == expectedRevisionId ? row : await _insertRevision(transaction, row);
  });

  Future<ScheduleRevision> syncSchedule(TermRef term, List<CourseRecord> courses, {required bool confirm, String? expectedRevisionId, required String now}) => _db.transaction((transaction) async {
    final store = await _loadTermStore(transaction, term);
    final before = store.head(term)?.id;
    if (confirm && before != expectedRevisionId) throw const RevisionConflict();
    final row = store.commitSync(term, courses, confirm: confirm, now: now)!;
    // 教务课表落了（或本来就一样），等用户来选的那份就作废了。
    await _releaseHold(transaction, term);
    return row.id == before ? row : await _insertRevision(transaction, row);
  });

  // 逐项合并教务课表：同 syncSchedule 在一个事务里核对 head，先记教务同步、再记合并结果（规则见 ScheduleStore.commitMerge）。
  Future<ScheduleRevision> mergeSchedule(TermRef term, List<CourseRecord> courses, List<CourseRecord> merged, String summary, {required String? expectedRevisionId, required String now}) => _db.transaction((transaction) async {
    // 连同最近一次教务同步的版本一起载入（走 (xn, xq, source, sequence) 索引、只取一行）：教务这份和它一样时不再重复记一版。
    final baseline = (await transaction.query('schedule_revision', columns: ['id'], where: "xn = ? AND xq = ? AND source = 'edu'", whereArgs: [term.xn, term.xq], orderBy: 'sequence DESC', limit: 1)).firstOrNull?['id'] as String?;
    final store = await _loadTermStore(transaction, term, revisionId: baseline);
    if (store.head(term)?.id != expectedRevisionId) throw const RevisionConflict();
    final normalized = normalizeSchedule(merged);
    validateSchedule(normalized);
    await _releaseHold(transaction, term);
    late ScheduleRevision last;
    for (final row in store.commitMerge(term, courses, normalized, summary, now)) {
      last = await _insertRevision(transaction, row);
    }
    return last;
  });

  // 三方合并的基准：这学期最近一次教务同步的版本（走 (xn, xq, source, sequence) 索引，只取一行）。
  Future<List<CourseRecord>?> latestEduCourses(TermRef term) async {
    final rows = await _db.query('schedule_revision', columns: ['courses_json'], where: "xn = ? AND xq = ? AND source = 'edu'", whereArgs: [term.xn, term.xq], orderBy: 'sequence DESC', limit: 1);
    return rows.isEmpty ? null : coursesFromJson(jsonDecode(rows.single['courses_json'] as String));
  }

  Future<void> _releaseHold(DatabaseExecutor executor, TermRef term) => executor.delete('schedule_sync_hold', where: 'xn = ? AND xq = ?', whereArgs: [term.xn, term.xq]);

  // 冲突的教务课表留着等用户来选；用户对同一份选过保留本地的不再变回等待。返回之后还等不等用户来选。
  Future<bool> holdSchedule(TermRef term, List<CourseRecord> courses, {required bool dismissed, required String now}) => _db.transaction((transaction) async {
    final rows = await transaction.query('schedule_sync_hold', columns: ['courses_json', 'dismissed'], where: 'xn = ? AND xq = ?', whereArgs: [term.xn, term.xq], limit: 1);
    final existing = rows.firstOrNull;
    if (!dismissed && existing?['dismissed'] == 1 && fingerprint(coursesFromJson(jsonDecode(existing!['courses_json'] as String))) == fingerprint(courses)) return false;
    await transaction.insert('schedule_sync_hold', {
      'xn': term.xn,
      'xq': term.xq,
      'courses_json': jsonEncode(courses.map((course) => course.toJson()).toList()),
      'fetched_at': now,
      'dismissed': dismissed ? 1 : 0,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    return !dismissed;
  });

  // 等用户来选的那几份，行数不超过学期数；学期名从 term 表补上。
  Future<List<HeldScheduleSync>> heldSchedules() async {
    final rows = await _db.rawQuery('''
SELECT hold.xn, hold.xq, hold.courses_json, hold.fetched_at, term.label FROM schedule_sync_hold hold
LEFT JOIN term ON term.xn = hold.xn AND term.xq = hold.xq
WHERE hold.dismissed = 0 ORDER BY hold.xn DESC, hold.xq DESC
''');
    return [
      for (final row in rows)
        HeldScheduleSync(
          term: TermRef(xn: row['xn'] as String, xq: row['xq'] as String, label: row['label'] as String? ?? ''),
          courses: coursesFromJson(jsonDecode(row['courses_json'] as String)),
          fetchedAt: row['fetched_at'] as String,
        ),
    ];
  }

  Future<AutoSyncView> readAutoSync() async {
    final row = (await _db.query('auto_sync', where: 'id = 1', limit: 1)).firstOrNull;
    if (row == null) return const AutoSyncView(setting: AutoSyncSetting(), status: AutoSyncStatus());
    DateTime? moment(Object? value) => value == null ? null : DateTime.parse(value as String);
    final years = row['years_json'] as String?;
    return AutoSyncView(
      setting: AutoSyncSetting(
        enabled: row['enabled'] == 1,
        interval: Duration(minutes: row['interval_minutes'] as int),
        years: years == null ? null : {...(jsonDecode(years) as List).cast<String>()},
        // 库里的名字认不出（别的版本写的）时跳过那一项、状态当没有，不让读设置抛错、自动同步悄悄停掉；一项内容都不剩时退回默认。
        contents: switch ({for (final name in (jsonDecode(row['contents_json'] as String) as List).cast<String>()) ?SyncContent.values.asNameMap()[name]}) {
          final contents when contents.isNotEmpty => contents,
          _ => const AutoSyncSetting().contents,
        },
      ),
      status: AutoSyncStatus(
        lastAttemptAt: moment(row['last_attempt_at']),
        lastSuccessAt: moment(row['last_success_at']),
        state: switch (row['last_state']) { final String name => AutoSyncState.values.asNameMap()[name], _ => null },
        message: row['last_message'] as String,
      ),
    );
  }

  Future<void> saveAutoSyncSetting(AutoSyncSetting setting, {required String now}) => _db.rawInsert('''
INSERT INTO auto_sync (id, enabled, interval_minutes, years_json, contents_json, updated_at) VALUES (1, ?, ?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET enabled = excluded.enabled, interval_minutes = excluded.interval_minutes, years_json = excluded.years_json,
  contents_json = excluded.contents_json, updated_at = excluded.updated_at
''', [
    setting.enabled ? 1 : 0,
    setting.interval.inMinutes,
    switch (setting.years) { final years? => jsonEncode([...years]..sort()), null => null },
    jsonEncode([for (final content in SyncContent.values) if (setting.contents.contains(content)) content.name]),
    now,
  ]);

  // 还没存过设置时先按默认值落一行，再写结果。
  Future<void> recordAutoSync(AutoSyncStatus status, {required String now}) => _db.transaction((transaction) async {
    await transaction.rawInsert('INSERT INTO auto_sync (id, enabled, interval_minutes, contents_json, updated_at) VALUES (1, 0, ?, ?, ?) ON CONFLICT(id) DO NOTHING', [
      autoSyncDefaultInterval.inMinutes,
      jsonEncode([for (final content in const AutoSyncSetting().contents) content.name]),
      now,
    ]);
    await transaction.update('auto_sync', {
      'last_attempt_at': status.lastAttemptAt?.toUtc().toIso8601String(),
      'last_success_at': status.lastSuccessAt?.toUtc().toIso8601String(),
      'last_state': status.state?.name,
      'last_message': status.message,
      'updated_at': now,
    }, where: 'id = 1');
  });

  Future<ScheduleRevision> restoreRevision(TermRef term, String id, {required String? expectedRevisionId, required String now}) => _db.transaction((transaction) async {
    final store = await _loadTermStore(transaction, term, revisionId: id);
    if (store.head(term)?.id != expectedRevisionId) throw const RevisionConflict();
    final row = store.restore(term, id, now);
    return row.id == expectedRevisionId ? row : await _insertRevision(transaction, row);
  });

  Stream<({String id, String source, String createdAt, String summary})> revisionSummaries(TermRef term) async* {
    String? afterDate;
    String? afterId;
    while (true) {
      final rows = await _db.query('schedule_revision',
        columns: ['id', 'source', 'created_at', 'summary'],
        where: 'xn = ? AND xq = ?${afterDate == null ? '' : ' AND (created_at, id) > (?, ?)'}',
        whereArgs: [term.xn, term.xq, if (afterDate != null) ...[afterDate, afterId]],
        orderBy: 'created_at ASC, id ASC',
        limit: 100,
      );
      for (final row in rows) {
        yield (id: row['id'] as String, source: row['source'] as String, createdAt: row['created_at'] as String, summary: row['summary'] as String);
      }
      if (rows.length < 100) return;
      afterDate = rows.last['created_at'] as String;
      afterId = rows.last['id'] as String;
    }
  }

  ScheduleRevision _revisionOf(Map<String, Object?> row) {
    return ScheduleRevision(
      id: row['id'] as String,
      termKey: '${row['xn']}-${row['xq']}',
      xn: row['xn'] as String,
      xq: row['xq'] as String,
      source: row['source'] as String,
      parentId: row['parent_id'] as String?,
      createdAt: row['created_at'] as String,
      summary: row['summary'] as String,
      courses: coursesFromJson(jsonDecode(row['courses_json'] as String)),
      sequence: row['sequence'] as int,
      operation: row['operation'] as String,
      restoredFromId: row['restored_from_id'] as String?,
    );
  }

  Future<void> insertRevision(ScheduleRevision row) => _db.transaction((transaction) async {
    final head = await transaction.query('schedule_head', where: 'xn = ? AND xq = ?', whereArgs: [row.xn, row.xq], limit: 1);
    if (head.firstOrNull?['revision_id'] != row.parentId) throw const RevisionConflict();
    await _insertRevision(transaction, row);
  });

  Future<ScheduleRevision> _insertRevision(Transaction transaction, ScheduleRevision row) async {
      final latest = await transaction.query('schedule_revision', columns: ['sequence'], where: 'xn = ? AND xq = ?', whereArgs: [row.xn, row.xq], orderBy: 'sequence DESC', limit: 1);
      final sequence = (latest.firstOrNull?['sequence'] as int? ?? 0) + 1;
      await transaction.rawInsert('INSERT INTO term (xn, xq, label) VALUES (?, ?, ?) ON CONFLICT(xn, xq) DO NOTHING', [row.xn, row.xq, row.termKey]);
      await transaction.insert('schedule_revision', {
        'id': row.id,
        'xn': row.xn,
        'xq': row.xq,
        'source': row.source,
        'parent_id': row.parentId,
        'created_at': row.createdAt,
        'summary': row.summary,
        'sequence': sequence,
        'operation': row.operation,
        'restored_from_id': row.restoredFromId,
        'courses_json': jsonEncode(row.courses.map((course) => course.toJson()).toList()),
      });
      await transaction.rawInsert(
        '''
INSERT INTO schedule_head (xn, xq, revision_id) VALUES (?, ?, ?)
ON CONFLICT(xn, xq) DO UPDATE SET revision_id = excluded.revision_id
''',
        [row.xn, row.xq, row.id],
      );
      await _pruneRevisions(transaction, row.xn, row.xq);
      return ScheduleRevision(id: row.id, termKey: row.termKey, xn: row.xn, xq: row.xq, source: row.source, parentId: row.parentId, createdAt: row.createdAt, summary: row.summary, courses: row.courses, sequence: sequence, operation: row.operation, restoredFromId: row.restoredFromId);
  }

  Future<String?> termStartDate(String xn, String xq) async {
    final rows = await _db.query('term', columns: ['start_date'], where: 'xn = ? AND xq = ?', whereArgs: [xn, xq]);
    if (rows.isEmpty) return null;
    return rows.single['start_date'] as String?;
  }

  Future<String?> gradesPayload(String xn, String xq) async {
    final rows = await _db.query('grades_cache', columns: ['payload_json'], where: 'xn = ? AND xq = ?', whereArgs: [xn, xq]);
    if (rows.isEmpty) return null;
    return rows.single['payload_json'] as String;
  }

  Future<Map<String, Object?>?> bellsRow(String xn, String xq) async {
    final rows = await _db.query('bells_cache', where: 'xn = ? AND xq = ?', whereArgs: [xn, xq]);
    if (rows.isEmpty) return null;
    return rows.single.cast<String, Object?>();
  }

  Future<TermRef?> bellsSource(String xn, String xq) async {
    final rows = await _db.query('term_bells_source', where: 'target_xn = ? AND target_xq = ?', whereArgs: [xn, xq]);
    if (rows.isEmpty) return null;
    final row = rows.single;
    final sourceXn = row['source_xn'] as String;
    final sourceXq = row['source_xq'] as String;
    final terms = await _db.query('term', columns: ['label'], where: 'xn = ? AND xq = ?', whereArgs: [sourceXn, sourceXq], limit: 1);
    return TermRef(xn: sourceXn, xq: sourceXq, label: terms.firstOrNull?['label'] as String? ?? '$sourceXn-$sourceXq');
  }

  Future<void> setBellsSource({required String targetXn, required String targetXq, required String sourceXn, required String sourceXq}) async {
    if (targetXn == sourceXn && targetXq == sourceXq) {
      await _db.delete('term_bells_source', where: 'target_xn = ? AND target_xq = ?', whereArgs: [targetXn, targetXq]);
      return;
    }
    await _db.insert('term_bells_source', {
      'target_xn': targetXn,
      'target_xq': targetXq,
      'source_xn': sourceXn,
      'source_xq': sourceXq,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, Object?>?> gradesRow(TermRef term) async {
    final rows = await _db.query('grades_cache', where: 'xn = ? AND xq = ?', whereArgs: [term.xn, term.xq], limit: 1);
    return rows.firstOrNull;
  }

  Future<List<Map<String, Object?>>> gradeYearRows(String year) => _db.rawQuery('''
SELECT term.xn, term.xq, term.label, grades_cache.fetched_at, grades_cache.summary_json,
CASE WHEN grades_cache.summary_json IS NULL THEN grades_cache.payload_json ELSE NULL END AS legacy_payload
FROM term LEFT JOIN grades_cache ON term.xn = grades_cache.xn AND term.xq = grades_cache.xq
WHERE term.xn = ? ORDER BY term.xq LIMIT 10
''', [year]);

  Future<void> backfillGradeSummaries(List<({TermRef term, String payload, String fetchedAt, String summary})> rows) async {
    if (rows.isEmpty) return;
    final batch = _db.batch();
    for (final row in rows) {
      batch.update('grades_cache', {'summary_json': row.summary}, where: 'xn = ? AND xq = ? AND fetched_at = ? AND payload_json = ? AND summary_json IS NULL', whereArgs: [row.term.xn, row.term.xq, row.fetchedAt, row.payload]);
    }
    await batch.commit(noResult: true);
  }

  Future<void> writeGrades(String xn, String xq, String fetchedAt, String payloadJson, {String? summaryJson}) async {
    await _db.insert('grades_cache', {
      'xn': xn, 'xq': xq, 'fetched_at': fetchedAt,
      'payload_json': payloadJson, 'summary_json': summaryJson,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> writeBells({
    required String xn,
    required String xq,
    required String fetchedAt,
    required bool empty,
    required String message,
    required String periodsJson,
  }) async {
    await _db.insert('bells_cache', {
      'xn': xn,
      'xq': xq,
      'fetched_at': fetchedAt,
      'empty': empty ? 1 : 0,
      'message': message,
      'periods_json': periodsJson,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}
