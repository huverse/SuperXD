import 'package:sqflite/sqflite.dart';

import 'package:superxd/toolbox/toolbox_store.dart';

// 短视频自己的本机库 short_video.db：偏好（解析来源、参与自动解析的来源、历史开关）与解析历史。
// 以前这两张表在百宝箱框架库里，第一次打开时从框架库搬过来（见 ToolboxStore.legacyShortVideoData）。
class ShortVideoStore {
  ShortVideoStore._(this._database);
  final Database _database;
  bool _closed = false;

  static const historyLimit = 80;
  static const historyLifetime = Duration(days: 30);

  static Future<ShortVideoStore> open(String path, {required ToolboxStore legacy}) async {
    final store = ShortVideoStore._(
      await openDatabase(
        path,
        version: 1,
        onCreate: (database, _) async {
          await database.execute('CREATE TABLE preferences (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
          await database.execute(
            'CREATE TABLE parse_history (id TEXT PRIMARY KEY, source_url TEXT NOT NULL, provider_id TEXT NOT NULL, title TEXT NOT NULL, kind TEXT NOT NULL, created_at INTEGER NOT NULL)',
          );
          await database.execute('CREATE INDEX parse_history_time ON parse_history (created_at DESC, id DESC)');
        },
      ),
    );
    await store._migrate(legacy);
    return store;
  }

  // 先把旧行写进本库（已有的不覆盖），提交后才删框架库里的旧表：中途失败下次打开重搬，不丢也不重复。
  Future<void> _migrate(ToolboxStore legacy) async {
    final data = await legacy.legacyShortVideoData();
    if (data == null) return;
    final batch = _database.batch();
    for (final row in data.preferences) {
      batch.insert('preferences', {'key': row['key'], 'value': row['value']}, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    for (final row in data.history) {
      batch.insert('parse_history', row, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    await batch.commit(noResult: true);
    await legacy.dropLegacyShortVideoTables();
  }

  Future<String?> preference(String key) async =>
      (await _database.query('preferences', where: 'key = ?', whereArgs: [key], limit: 1)).firstOrNull?['value'] as String?;

  Future<void> setPreference(String key, String value) async {
    await _database.insert('preferences', {'key': key, 'value': value}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // [人工决策-2026-09-29 16:41:32] 历史默认开启：未设置视为开启，用户手动关闭的保持关闭；仅本机80条/30天；不保存签名媒体地址，删历史不删下载文件。
  Future<void> addHistory({
    required String id,
    required Uri sourceUrl,
    required String providerId,
    required String title,
    required String kind,
  }) async {
    if (await preference('history_enabled') == 'false') return;
    await _database.transaction((transaction) async {
      await transaction.insert('parse_history', {
        'id': id,
        'source_url': sourceUrl.toString(),
        'provider_id': providerId,
        'title': title,
        'kind': kind,
        'created_at': DateTime.now().toUtc().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await _pruneHistory(transaction);
    });
  }

  static Future<void> _pruneHistory(DatabaseExecutor database) async {
    await database.delete(
      'parse_history',
      where: 'created_at < ?',
      whereArgs: [DateTime.now().toUtc().subtract(historyLifetime).millisecondsSinceEpoch],
    );
    await database.rawDelete(
      'DELETE FROM parse_history WHERE id NOT IN (SELECT id FROM parse_history ORDER BY created_at DESC, id DESC LIMIT $historyLimit)',
    );
  }

  Future<List<Map<String, Object?>>> history({int limit = historyLimit}) async {
    await _pruneHistory(_database);
    return _database.query('parse_history', orderBy: 'created_at DESC, id DESC', limit: limit);
  }

  Future<void> deleteHistory(String id) async {
    await _database.delete('parse_history', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> clearHistory() async {
    await _database.delete('parse_history');
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _database.close();
  }

  // 清除数据时用：关库并删掉库文件（含日志文件），下次打开是一份空库。
  Future<void> destroy() async {
    final path = _database.path;
    await close();
    await deleteDatabase(path);
  }
}
