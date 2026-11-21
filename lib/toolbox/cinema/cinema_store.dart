import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

import 'package:superxd/toolbox/cinema/cinema_models.dart';

// 电影院自己的本机库 cinema.db（设备级，清除数据时整库删掉）：
// - package：上次验签通过的规则包载荷（只留一份，拉不到新的就照旧用它）；
// - consent：用过哪些源与云解析（按规则 id 与接口主机记，换了主机或新加的源要重新同意）；
// - history：看过的片与看到哪，最多 cinemaHistoryLimit 条、超过 cinemaHistoryLifetime 没再看的删掉；
// - source_stat（第 2 版起）：各片源最近一次播成、没播成的时刻与播成那次的首帧用时（选集页排片源与标注用，人工决策见 cinema_service.dart 的 recordPlayback），
//   每个源一行（行数不超过规则包里的源数），超过 cinemaSourceStatLifetime 没再播的删掉。
// - title_source（第 3 版起）：看过的片在各源里的编号、原名与备注（续播时直接有别的源可换，不用再搜），跟着 history 走：
//   每部最多 cinemaTitleSourceLimit 个，history 里没有了（删掉、超过上限或期限被清）就一起删。
// - preference（第 4 版起）：这台手机上电影院的设置，每项一行（现在只有播放内核 engine，人工决策见 cinema_engine.dart 文件头）。
const cinemaHistoryLimit = 50;
const cinemaHistoryLifetime = Duration(days: 180);
const cinemaSourceStatLifetime = Duration(days: 30);
const cinemaTitleSourceLimit = 32;

const _createSourceStat = 'CREATE TABLE source_stat (rule_id TEXT PRIMARY KEY, ok_at INTEGER, fail_at INTEGER, first_frame_ms INTEGER, updated_at INTEGER NOT NULL)';
const _createPreference = 'CREATE TABLE preference (key TEXT PRIMARY KEY, value TEXT NOT NULL)';
const _createTitleSource = 'CREATE TABLE title_source (key TEXT NOT NULL, position INTEGER NOT NULL, rule_id TEXT NOT NULL, source TEXT NOT NULL, name TEXT NOT NULL, remarks TEXT NOT NULL, PRIMARY KEY (key, position))';

class CinemaStore {
  CinemaStore._(this._database);
  final Database _database;

  static Future<CinemaStore> open(String path) async => CinemaStore._(
    // 单实例并回滚遗留的事务：退出再进入时接回旧引擎留下的连接（人工决策见 local/account_store.dart 的 open）。
    await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 4,
        rollbackActiveTransactionOnOpen: true,
        onUpgrade: (database, from, _) async {
          if (from < 2) await database.execute(_createSourceStat);
          if (from < 3) await database.execute(_createTitleSource);
          if (from < 4) await database.execute(_createPreference);
        },
        onCreate: (database, _) async {
          await database.execute('CREATE TABLE package (id INTEGER PRIMARY KEY CHECK (id = 1), version INTEGER NOT NULL, payload BLOB NOT NULL, fetched_at INTEGER NOT NULL)');
          await database.execute('CREATE TABLE consent (subject TEXT PRIMARY KEY, version TEXT NOT NULL)');
          await database.execute(
            'CREATE TABLE history (key TEXT PRIMARY KEY, name TEXT NOT NULL, cover TEXT NOT NULL, rule_id TEXT NOT NULL, source TEXT NOT NULL, road INTEGER NOT NULL, episode INTEGER NOT NULL, episode_name TEXT NOT NULL, position_ms INTEGER NOT NULL, duration_ms INTEGER NOT NULL, updated_at INTEGER NOT NULL)',
          );
          await database.execute('CREATE INDEX history_time ON history (updated_at DESC)');
          await database.execute(_createSourceStat);
          await database.execute(_createTitleSource);
          await database.execute(_createPreference);
        },
      ),
    ),
  );

  Future<({int version, Uint8List payload, DateTime fetchedAt})?> package() async {
    final row = (await _database.query('package', limit: 1)).firstOrNull;
    if (row == null) return null;
    return (version: row['version'] as int, payload: row['payload'] as Uint8List, fetchedAt: DateTime.fromMillisecondsSinceEpoch(row['fetched_at'] as int, isUtc: true));
  }

  Future<void> savePackage(int version, List<int> payload, DateTime fetchedAt) async {
    await _database.insert('package', {'id': 1, 'version': version, 'payload': Uint8List.fromList(payload), 'fetched_at': fetchedAt.toUtc().millisecondsSinceEpoch}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // 只记拉取时刻（拉到的不比本机新时）。
  Future<void> touchPackage(DateTime fetchedAt) async {
    await _database.update('package', {'fetched_at': fetchedAt.toUtc().millisecondsSinceEpoch}, where: 'id = 1');
  }

  Future<String?> preference(String key) async => (await _database.query('preference', where: 'key = ?', whereArgs: [key], limit: 1)).firstOrNull?['value'] as String?;

  Future<void> savePreference(String key, String value) async {
    await _database.insert('preference', {'key': key, 'value': value}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, String>> consents() async => {
    for (final row in await _database.query('consent')) row['subject'] as String: row['version'] as String,
  };

  Future<void> grant(Map<String, String> subjects) async {
    final batch = _database.batch();
    for (final entry in subjects.entries) {
      batch.insert('consent', {'subject': entry.key, 'version': entry.value}, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<List<CinemaHistory>> history({int limit = cinemaHistoryLimit}) async => [
    for (final row in await _database.query('history', orderBy: 'updated_at DESC', limit: limit)) _historyOf(row),
  ];

  Future<CinemaHistory?> historyOf(String key) async {
    final row = (await _database.query('history', where: 'key = ?', whereArgs: [key], limit: 1)).firstOrNull;
    return row == null ? null : _historyOf(row);
  }

  Future<void> saveHistory(CinemaHistory entry) async {
    await _database.transaction((transaction) async {
      await transaction.insert('history', {
        'key': entry.key,
        'name': entry.name,
        'cover': entry.cover,
        'rule_id': entry.ruleId,
        'source': entry.source,
        'road': entry.road,
        'episode': entry.episode,
        'episode_name': entry.episodeName,
        'position_ms': entry.position.inMilliseconds,
        'duration_ms': entry.duration.inMilliseconds,
        'updated_at': entry.updatedAt.toUtc().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      final cutoff = entry.updatedAt.toUtc().subtract(cinemaHistoryLifetime).millisecondsSinceEpoch;
      await transaction.delete('history', where: 'updated_at < ?', whereArgs: [cutoff]);
      await transaction.execute('DELETE FROM history WHERE key NOT IN (SELECT key FROM history ORDER BY updated_at DESC LIMIT ?)', [cinemaHistoryLimit]);
      await transaction.execute('DELETE FROM title_source WHERE key NOT IN (SELECT key FROM history)');
    });
  }

  Future<void> deleteHistory(String key) async {
    await _database.transaction((transaction) async {
      await transaction.delete('history', where: 'key = ?', whereArgs: [key]);
      await transaction.delete('title_source', where: 'key = ?', whereArgs: [key]);
    });
  }

  // 一部看过的片的各个源（按给的先后，最多 cinemaTitleSourceLimit 个），整份换掉；history 里没有这部就不记。
  Future<void> saveTitleSources(String key, List<CinemaSourceRef> sources) async {
    await _database.transaction((transaction) async {
      await transaction.delete('title_source', where: 'key = ?', whereArgs: [key]);
      if ((await transaction.query('history', columns: ['key'], where: 'key = ?', whereArgs: [key], limit: 1)).isEmpty) return;
      final batch = transaction.batch();
      for (final (position, ref) in sources.take(cinemaTitleSourceLimit).indexed) {
        batch.insert('title_source', {'key': key, 'position': position, 'rule_id': ref.ruleId, 'source': ref.source, 'name': ref.name, 'remarks': ref.remarks});
      }
      await batch.commit(noResult: true);
    });
  }

  Future<List<CinemaSourceRef>> titleSources(String key) async => [
    for (final row in await _database.query('title_source', where: 'key = ?', whereArgs: [key], orderBy: 'position', limit: cinemaTitleSourceLimit))
      CinemaSourceRef(ruleId: row['rule_id'] as String, source: row['source'] as String, name: row['name'] as String, remarks: row['remarks'] as String),
  ];

  // 各片源最近的播放结果；先删掉超过 cinemaSourceStatLifetime 没再播的。
  Future<Map<String, CinemaSourceStat>> sourceStats(DateTime now) async {
    await _database.delete('source_stat', where: 'updated_at < ?', whereArgs: [now.toUtc().subtract(cinemaSourceStatLifetime).millisecondsSinceEpoch]);
    DateTime? time(Object? value) => value == null ? null : DateTime.fromMillisecondsSinceEpoch(value as int, isUtc: true);
    return {
      for (final row in await _database.query('source_stat'))
        row['rule_id'] as String: CinemaSourceStat(okAt: time(row['ok_at']), failAt: time(row['fail_at']), firstFrame: row['first_frame_ms'] == null ? null : Duration(milliseconds: row['first_frame_ms'] as int)),
    };
  }

  // 记一次播放：播成了记时刻与首帧用时，没播成只记时刻（另一项留着）。
  Future<void> recordPlayback(String ruleId, {required bool ok, Duration? firstFrame, required DateTime at}) async {
    final time = at.toUtc().millisecondsSinceEpoch;
    await _database.execute(
      ok
          ? 'INSERT INTO source_stat (rule_id, ok_at, first_frame_ms, updated_at) VALUES (?, ?, ?, ?) ON CONFLICT(rule_id) DO UPDATE SET ok_at = excluded.ok_at, first_frame_ms = excluded.first_frame_ms, updated_at = excluded.updated_at'
          : 'INSERT INTO source_stat (rule_id, fail_at, updated_at) VALUES (?, ?, ?) ON CONFLICT(rule_id) DO UPDATE SET fail_at = excluded.fail_at, updated_at = excluded.updated_at',
      ok ? [ruleId, time, firstFrame?.inMilliseconds, time] : [ruleId, time, time],
    );
  }

  Future<void> close() => _database.close();

  static CinemaHistory _historyOf(Map<String, Object?> row) => CinemaHistory(
    key: row['key'] as String,
    name: row['name'] as String,
    cover: row['cover'] as String,
    ruleId: row['rule_id'] as String,
    source: row['source'] as String,
    road: row['road'] as int,
    episode: row['episode'] as int,
    episodeName: row['episode_name'] as String,
    position: Duration(milliseconds: row['position_ms'] as int),
    duration: Duration(milliseconds: row['duration_ms'] as int),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int, isUtc: true),
  );
}
