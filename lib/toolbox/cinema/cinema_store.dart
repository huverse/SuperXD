import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

import 'package:superxd/toolbox/cinema/cinema_models.dart';

// 电影院自己的本机库 cinema.db（设备级，清除数据时整库删掉）：
// - package：上次验签通过的规则包载荷（只留一份，拉不到新的就照旧用它）；
// - consent：用过哪些源与云解析（按规则 id 与接口主机记，换了主机或新加的源要重新同意）；
// - history：看过的片与看到哪，最多 cinemaHistoryLimit 条、超过 cinemaHistoryLifetime 没再看的删掉。
const cinemaHistoryLimit = 50;
const cinemaHistoryLifetime = Duration(days: 180);

class CinemaStore {
  CinemaStore._(this._database);
  final Database _database;

  static Future<CinemaStore> open(String path) async => CinemaStore._(
    // 单实例并回滚遗留的事务：退出再进入时接回旧引擎留下的连接（人工决策见 local/account_store.dart 的 open）。
    await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        rollbackActiveTransactionOnOpen: true,
        onCreate: (database, _) async {
          await database.execute('CREATE TABLE package (id INTEGER PRIMARY KEY CHECK (id = 1), version INTEGER NOT NULL, payload BLOB NOT NULL, fetched_at INTEGER NOT NULL)');
          await database.execute('CREATE TABLE consent (subject TEXT PRIMARY KEY, version TEXT NOT NULL)');
          await database.execute(
            'CREATE TABLE history (key TEXT PRIMARY KEY, name TEXT NOT NULL, cover TEXT NOT NULL, rule_id TEXT NOT NULL, source TEXT NOT NULL, road INTEGER NOT NULL, episode INTEGER NOT NULL, episode_name TEXT NOT NULL, position_ms INTEGER NOT NULL, duration_ms INTEGER NOT NULL, updated_at INTEGER NOT NULL)',
          );
          await database.execute('CREATE INDEX history_time ON history (updated_at DESC)');
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
    });
  }

  Future<void> deleteHistory(String key) async {
    await _database.delete('history', where: 'key = ?', whereArgs: [key]);
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
