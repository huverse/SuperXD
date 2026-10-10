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
      },
      onUpgrade: (database, oldVersion, _) async {
        if (oldVersion < 2) {
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
  Future<void> revokeConsent(String providerId) async {
    await _database.delete('consent', where: 'service = ?', whereArgs: [providerId]);
  }

  // 短视频的解析历史与偏好以前放在本库（toolbox_preferences、parse_history 两张表），现在归短视频自己的库：
  // 它打开时先读出旧表的行搬过去，搬完再删旧表（先搬后删，中途失败下次重搬，INSERT OR IGNORE 不重复）。
  // 新装的库不再建这两张表。
  Future<({List<Map<String, Object?>> preferences, List<Map<String, Object?>> history})?> legacyShortVideoData() async {
    final tables = {
      for (final row in await _database.query('sqlite_master', columns: ['name'], where: "type = 'table' AND name IN ('toolbox_preferences', 'parse_history')"))
        row['name'] as String,
    };
    if (tables.isEmpty) return null;
    return (
      preferences: tables.contains('toolbox_preferences') ? await _database.query('toolbox_preferences') : const <Map<String, Object?>>[],
      history: tables.contains('parse_history') ? await _database.query('parse_history', limit: 80) : const <Map<String, Object?>>[],
    );
  }

  Future<void> dropLegacyShortVideoTables() async {
    await _database.transaction((transaction) async {
      await transaction.execute('DROP TABLE IF EXISTS toolbox_preferences');
      await transaction.execute('DROP INDEX IF EXISTS parse_history_time');
      await transaction.execute('DROP TABLE IF EXISTS parse_history');
    });
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
