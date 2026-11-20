import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/toolbox/cinema/cinema_models.dart';
import 'package:superxd/toolbox/cinema/cinema_rule.dart';

// 电影院自己的本机库 cinema.db（设备级，清除数据时整库删掉）：
// - package：上次验签通过的规则包载荷（只留一份，拉不到新的就照旧用它）；
// - consent：用过哪些源与云解析（按规则 id 与接口主机记，换了主机或新加的源要重新同意）；
// - history：看过的片与看到哪，最多 cinemaHistoryLimit 条、超过 cinemaHistoryLifetime 没再看的删掉。
// - catalog、catalog_meta（第 2 版起）：片名目录型的源的本机片名目录（编号、片名与折叠写法）与它来自哪份底包、补到了哪一刻；
//   每个源最多 cinemaCatalogEntryLimit 条（底包本身也不许超过），源从规则包里拿掉时一并删掉（dropCatalogs）。
const cinemaHistoryLimit = 50;
const cinemaHistoryLifetime = Duration(days: 180);
// 一条多行 INSERT 写几条（4 个参数一条，SQLite 3.28 默认最多 999 个参数）。
const _catalogInsertRows = 200;

class CinemaStore {
  CinemaStore._(this._database);
  final Database _database;

  static Future<CinemaStore> open(String path) async => CinemaStore._(
    // 单实例并回滚遗留的事务：退出再进入时接回旧引擎留下的连接（人工决策见 local/account_store.dart 的 open）。
    await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 2,
        rollbackActiveTransactionOnOpen: true,
        onUpgrade: (database, from, _) async {
          if (from < 2) await _createCatalog(database);
        },
        onCreate: (database, _) async {
          await _createCatalog(database);
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

  static Future<void> _createCatalog(Database database) async {
    await database.execute('CREATE TABLE catalog (rule_id TEXT NOT NULL, source TEXT NOT NULL, name TEXT NOT NULL, folded TEXT NOT NULL, PRIMARY KEY (rule_id, source)) WITHOUT ROWID');
    await database.execute('CREATE TABLE catalog_meta (rule_id TEXT PRIMARY KEY, file TEXT NOT NULL, synced_at INTEGER NOT NULL, entries INTEGER NOT NULL)');
  }

  // 这个源的本机片名目录来自哪份底包、补到了哪一刻、有几条；还没有为空。
  Future<({String file, DateTime syncedAt, int entries})?> catalogMeta(String ruleId) async {
    final row = (await _database.query('catalog_meta', where: 'rule_id = ?', whereArgs: [ruleId], limit: 1)).firstOrNull;
    if (row == null) return null;
    return (file: row['file'] as String, syncedAt: DateTime.fromMillisecondsSinceEpoch(row['synced_at'] as int, isUtc: true), entries: row['entries'] as int);
  }

  // 换成一份底包：同一事务里删掉旧的、整批写进新的（多行 INSERT 分批），记下来源与起点。
  Future<void> replaceCatalog(String ruleId, String file, DateTime syncedAt, List<(String, String)> entries) async {
    await _database.transaction((transaction) async {
      await transaction.delete('catalog', where: 'rule_id = ?', whereArgs: [ruleId]);
      await _insertCatalog(transaction, ruleId, entries);
      await transaction.insert('catalog_meta', {'rule_id': ruleId, 'file': file, 'synced_at': syncedAt.toUtc().millisecondsSinceEpoch, 'entries': entries.length}, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  // 补上增量（同编号的改名覆盖）并记下补到的时刻；会超过上限时这批不加（上限是现在上游规模的三倍，等维护者换新底包），只记时刻。
  Future<int> mergeCatalog(String ruleId, DateTime syncedAt, List<(String, String)> entries) => _database.transaction((transaction) async {
    final count = Sqflite.firstIntValue(await transaction.rawQuery('SELECT COUNT(*) FROM catalog WHERE rule_id = ?', [ruleId])) ?? 0;
    if (count + entries.length <= cinemaCatalogEntryLimit) {
      await _insertCatalog(transaction, ruleId, entries);
    } else {
      campusLog('[Cinema] action=catalog_full rule=$ruleId count=$count');
    }
    final total = Sqflite.firstIntValue(await transaction.rawQuery('SELECT COUNT(*) FROM catalog WHERE rule_id = ?', [ruleId])) ?? 0;
    await transaction.update('catalog_meta', {'synced_at': syncedAt.toUtc().millisecondsSinceEpoch, 'entries': total}, where: 'rule_id = ?', whereArgs: [ruleId]);
    return total;
  });

  // 本机找片名：折叠写法里含关键字的，完全一样的在前、开头一样的其次、短的在前。全表扫一遍（十几万条在手机上几十毫秒），不用索引。
  Future<List<(String, String)>> searchCatalog(String ruleId, String folded, {required int limit}) async {
    final pattern = folded.replaceAllMapped(RegExp(r'[\\%_]'), (match) => '\\${match[0]}');
    final rows = await _database.rawQuery(
      "SELECT source, name FROM catalog WHERE rule_id = ? AND folded LIKE ? ESCAPE '\\' ORDER BY folded = ? DESC, folded LIKE ? ESCAPE '\\' DESC, length(folded), source LIMIT ?",
      [ruleId, '%$pattern%', folded, '$pattern%', limit],
    );
    return [for (final row in rows) (row['source'] as String, row['name'] as String)];
  }

  // 规则包里已经没有的片名目录型源：本机目录一并删掉。
  Future<void> dropCatalogs(Set<String> keep) async {
    final placeholders = List.filled(keep.length, '?').join(', ');
    await _database.transaction((transaction) async {
      for (final table in ['catalog', 'catalog_meta']) {
        await transaction.delete(table, where: keep.isEmpty ? null : 'rule_id NOT IN ($placeholders)', whereArgs: keep.isEmpty ? null : [...keep]);
      }
    });
  }

  static Future<void> _insertCatalog(Transaction transaction, String ruleId, List<(String, String)> entries) async {
    for (var start = 0; start < entries.length; start += _catalogInsertRows) {
      final chunk = entries.sublist(start, (start + _catalogInsertRows).clamp(0, entries.length));
      await transaction.rawInsert(
        'INSERT OR REPLACE INTO catalog (rule_id, source, name, folded) VALUES ${List.filled(chunk.length, '(?, ?, ?, ?)').join(', ')}',
        [for (final (source, name) in chunk) ...[ruleId, source, name, cinemaFold(name)]],
      );
    }
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
