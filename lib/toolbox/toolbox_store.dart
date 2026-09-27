import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'package:superxd/toolbox/toolbox_models.dart';

class ToolboxStore {
  ToolboxStore._(this._database);
  final Database _database;

  static Future<ToolboxStore> open(String path) async => ToolboxStore._(
    await openDatabase(
      path,
      version: 2,
      onCreate: (database, _) async {
        await database.execute(
          'CREATE TABLE downloads (id TEXT PRIMARY KEY, tool_id TEXT NOT NULL, terminal INTEGER NOT NULL, updated_at INTEGER NOT NULL, payload TEXT NOT NULL)',
        );
        await database.execute(
          'CREATE INDEX downloads_state_time ON downloads (terminal, updated_at)',
        );
        await database.execute(
          'CREATE TABLE consent (service TEXT PRIMARY KEY, version TEXT NOT NULL)',
        );
        await database.execute(
          'CREATE TABLE resources (tool_id TEXT PRIMARY KEY, version TEXT NOT NULL, hash TEXT NOT NULL, bytes INTEGER NOT NULL)',
        );
        await _createMediaTables(database);
      },
      onUpgrade: (database, oldVersion, _) async {
        if (oldVersion < 2) {
          await _createMediaTables(database);
          // 旧同意仅属于BugPK，不能扩大成对未来所有解析源的授权。
          await database.rawInsert(
            "INSERT OR IGNORE INTO consent(service,version) SELECT 'bugpk', version FROM consent WHERE service = 'short_video'",
          );
          await database.delete(
            'consent',
            where: 'service = ?',
            whereArgs: ['short_video'],
          );
        }
      },
    ),
  );

  static Future<void> _createMediaTables(Database database) async {
    await database.execute(
      'CREATE TABLE toolbox_preferences (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
    );
    await database.execute(
      'CREATE TABLE parse_history (id TEXT PRIMARY KEY, source_url TEXT NOT NULL, provider_id TEXT NOT NULL, title TEXT NOT NULL, kind TEXT NOT NULL, created_at INTEGER NOT NULL)',
    );
    await database.execute(
      'CREATE INDEX parse_history_time ON parse_history (created_at DESC, id DESC)',
    );
  }

  Future<List<ToolboxDownload>> downloads() async {
    final rows = await _database.query(
      'downloads',
      orderBy: 'terminal, updated_at DESC',
      limit: 1120,
    );
    return rows
        .map(
          (row) => ToolboxDownload.fromJson(
            jsonDecode(row['payload'] as String) as Map<String, dynamic>,
          ),
        )
        .toList();
  }

  Future<void> putDownload(ToolboxDownload download) async {
    await _database.insert('downloads', {
      'id': download.id,
      'tool_id': download.toolId,
      'terminal': download.terminal ? 1 : 0,
      'updated_at': download.updatedAt.millisecondsSinceEpoch,
      'payload': jsonEncode(download.toJson()),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> putDownloads(List<ToolboxDownload> downloads) async {
    final batch = _database.batch();
    for (final item in downloads) {
      batch.insert('downloads', {
        'id': item.id,
        'tool_id': item.toolId,
        'terminal': item.terminal ? 1 : 0,
        'updated_at': item.updatedAt.millisecondsSinceEpoch,
        'payload': jsonEncode(item.toJson()),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<void> removeDownload(String id) async {
    await _database.delete('downloads', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> removeDownloads(List<String> ids) async {
    if (ids.isEmpty) return;
    await _database.delete(
      'downloads',
      where: 'id IN (${List.filled(ids.length, '?').join(',')})',
      whereArgs: ids,
    );
  }

  Future<bool> consent(String providerId, String version) async =>
      (await _database.query(
        'consent',
        where: 'service = ? AND version = ?',
        whereArgs: [providerId, version],
        limit: 1,
      )).isNotEmpty;
  Future<void> grantConsent(String providerId, String version) async {
    await _database.insert('consent', {
      'service': providerId,
      'version': version,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String?> preference(String key) async =>
      (await _database.query(
            'toolbox_preferences',
            where: 'key = ?',
            whereArgs: [key],
            limit: 1,
          )).firstOrNull?['value']
          as String?;
  Future<void> setPreference(String key, String value) async {
    await _database.insert('toolbox_preferences', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // [人工决策-2026-09-27 21:47:55] 历史默认关闭，开启后仅本机80条/30天；不保存签名媒体地址，删历史不删下载文件。
  Future<void> addHistory({
    required String id,
    required Uri sourceUrl,
    required String providerId,
    required String title,
    required String kind,
  }) async {
    if (await preference('history_enabled') != 'true') return;
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
      whereArgs: [
        DateTime.now()
            .toUtc()
            .subtract(const Duration(days: 30))
            .millisecondsSinceEpoch,
      ],
    );
    await database.rawDelete(
      'DELETE FROM parse_history WHERE id NOT IN (SELECT id FROM parse_history ORDER BY created_at DESC, id DESC LIMIT 80)',
    );
  }

  Future<List<Map<String, Object?>>> history() async {
    await _pruneHistory(_database);
    return _database.query(
      'parse_history',
      orderBy: 'created_at DESC, id DESC',
      limit: 80,
    );
  }

  Future<void> deleteHistory(String id) async {
    await _database.delete('parse_history', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> clearHistory() async {
    await _database.delete('parse_history');
  }

  Future<Map<String, Object?>?> resource(String toolId) async =>
      (await _database.query(
        'resources',
        where: 'tool_id = ?',
        whereArgs: [toolId],
        limit: 1,
      )).firstOrNull;
  Future<void> putResource(String toolId, ToolboxResource resource) async {
    await _database.insert('resources', {
      'tool_id': toolId,
      'version': resource.version,
      'hash': resource.sha256,
      'bytes': resource.bytes,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> removeResource(String toolId) async {
    await _database.delete(
      'resources',
      where: 'tool_id = ?',
      whereArgs: [toolId],
    );
  }

  Future<void> close() => _database.close();
}
