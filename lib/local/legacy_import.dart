import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

import 'package:superxd/domain/account.dart';

const _chunkSize = 200;

Future<LegacyImportReport> importLegacyDatabase({required DatabaseExecutor legacy, required Transaction target, required String legacyKey}) async {
  final version = (await legacy.rawQuery('PRAGMA user_version')).single.values.single as int;
  if (version < 1 || version > 2) throw StateError('不支持的旧数据库版本');
  final completed = await target.query('legacy_import_marker', where: 'legacy_key = ?', whereArgs: [legacyKey], limit: 1);
  if (completed.isNotEmpty) {
    return LegacyImportReport(imported: completed.single['imported'] as int, skipped: completed.single['skipped'] as int, alreadyImported: true);
  }
  final revisionPrefix = 'legacy:${sha256.convert(utf8.encode(legacyKey))}:';
  var imported = 0;
  var skipped = 0;

  // 临时表只记录本事务真正新增的依赖；冲突 cache/revision 不能被旧引用意外绑定。
  await target.execute('CREATE TEMP TABLE legacy_added_revision (id TEXT PRIMARY KEY)');
  await target.execute('CREATE TEMP TABLE legacy_added_bells (xn TEXT NOT NULL, xq TEXT NOT NULL, PRIMARY KEY (xn, xq))');
  try {
    await for (final rows in _pages(legacy, 'term', ['xn', 'xq'])) {
      final existing = await _matchingRows(target, 'term', ['xn', 'xq'], rows);
      final batch = target.batch();
      for (final row in rows) {
        final saved = existing[_rowKey(row, ['xn', 'xq'])];
        if (saved == null) {
          batch.insert('term', {...row, 'is_current': 0});
          imported++;
        } else if ((saved['start_date'] == null || saved['start_date'] == '') && row['start_date'] != null && row['start_date'] != '') {
          batch.update('term', {'start_date': row['start_date']}, where: 'xn = ? AND xq = ?', whereArgs: [row['xn'], row['xq']]);
          imported++;
        } else {
          skipped++;
        }
      }
      await batch.commit(noResult: true);
    }

    final latestSequence = await target.query('schedule_revision', columns: ['sequence'], orderBy: 'sequence DESC', limit: 1);
    var sequence = latestSequence.firstOrNull?['sequence'] as int? ?? 0;
    await for (final original in _pages(legacy, 'schedule_revision', ['rowid'])) {
      final rows = original.map((row) => <String, Object?>{
        ...Map.of(row)..remove('rowid'),
        'id': '$revisionPrefix${row['id']}',
        'parent_id': row['parent_id'] == null ? null : '$revisionPrefix${row['parent_id']}',
      }).toList();
      final existing = await _matchingRows(target, 'schedule_revision', ['id'], rows);
      final batch = target.batch();
      for (final row in rows) {
        if (existing.containsKey(_rowKey(row, ['id']))) {
          skipped++;
          continue;
        }
        batch.insert('schedule_revision', {...row, 'sequence': ++sequence, 'operation': row['source'] == 'edu' ? 'sync' : 'edit'});
        batch.insert('legacy_added_revision', {'id': row['id']});
        imported++;
      }
      await batch.commit(noResult: true);
    }

    await for (final rows in _pages(legacy, 'schedule_head', ['xn', 'xq'])) {
      final existing = await _matchingRows(target, 'schedule_head', ['xn', 'xq'], rows);
      final mapped = rows.map((row) => <String, Object?>{'id': '$revisionPrefix${row['revision_id']}'}).toList();
      final added = await _matchingRows(target, 'legacy_added_revision', ['id'], mapped);
      final revisions = await _matchingRows(target, 'schedule_revision', ['id'], mapped);
      final batch = target.batch();
      for (final row in rows) {
        final revisionId = '$revisionPrefix${row['revision_id']}';
        final revisionKey = _rowKey({'id': revisionId}, ['id']);
        final revision = revisions[revisionKey];
        if (existing.containsKey(_rowKey(row, ['xn', 'xq'])) || !added.containsKey(revisionKey) || revision?['xn'] != row['xn'] || revision?['xq'] != row['xq']) {
          skipped++;
          continue;
        }
        batch.insert('schedule_head', {...row, 'revision_id': revisionId});
        imported++;
      }
      await batch.commit(noResult: true);
    }

    for (final table in ['grades_cache', 'bells_cache']) {
      await for (final rows in _pages(legacy, table, ['xn', 'xq'])) {
        final existing = await _matchingRows(target, table, ['xn', 'xq'], rows);
        final batch = target.batch();
        for (final row in rows) {
          if (existing.containsKey(_rowKey(row, ['xn', 'xq']))) {
            skipped++;
            continue;
          }
          batch.insert(table, row);
          if (table == 'bells_cache') batch.insert('legacy_added_bells', {'xn': row['xn'], 'xq': row['xq']});
          imported++;
        }
        await batch.commit(noResult: true);
      }
    }

    final sourceTables = await legacy.rawQuery("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'term_bells_source' LIMIT 1");
    if (sourceTables.isNotEmpty) {
      await for (final rows in _pages(legacy, 'term_bells_source', ['target_xn', 'target_xq'])) {
        final existing = await _matchingRows(target, 'term_bells_source', ['target_xn', 'target_xq'], rows);
        final sourceKeys = rows.map((row) => <String, Object?>{'xn': row['source_xn'], 'xq': row['source_xq']}).toList();
        final targetKeys = rows.map((row) => <String, Object?>{'xn': row['target_xn'], 'xq': row['target_xq']}).toList();
        final addedSources = await _matchingRows(target, 'legacy_added_bells', ['xn', 'xq'], sourceKeys);
        final originalSources = await _matchingRows(legacy, 'bells_cache', ['xn', 'xq'], sourceKeys);
        final targetCaches = await _matchingRows(target, 'bells_cache', ['xn', 'xq'], targetKeys);
        final addedTargets = await _matchingRows(target, 'legacy_added_bells', ['xn', 'xq'], targetKeys);
        final batch = target.batch();
        for (final row in rows) {
          final sourceKey = _rowKey({'xn': row['source_xn'], 'xq': row['source_xq']}, ['xn', 'xq']);
          final targetKey = _rowKey({'xn': row['target_xn'], 'xq': row['target_xq']}, ['xn', 'xq']);
          final source = originalSources[sourceKey];
          if (existing.containsKey(_rowKey(row, ['target_xn', 'target_xq'])) ||
              !addedSources.containsKey(sourceKey) || source == null || source['empty'] != 0 || source['periods_json'] == '[]' ||
              sourceKey == targetKey || (targetCaches.containsKey(targetKey) && !addedTargets.containsKey(targetKey))) {
            skipped++;
            continue;
          }
          batch.insert('term_bells_source', row);
          imported++;
        }
        await batch.commit(noResult: true);
      }
    }
    await target.insert('legacy_import_marker', {'legacy_key': legacyKey, 'imported': imported, 'skipped': skipped});
  } finally {
    await target.execute('DROP TABLE legacy_added_revision');
    await target.execute('DROP TABLE legacy_added_bells');
  }
  return LegacyImportReport(imported: imported, skipped: skipped);
}

Stream<List<Map<String, Object?>>> _pages(DatabaseExecutor database, String table, List<String> keys) async* {
  List<Object?>? after;
  while (true) {
    final keyExpression = keys.length == 1 ? keys.single : '(${keys.join(', ')})';
    final cursorExpression = keys.length == 1 ? '?' : '(${List.filled(keys.length, '?').join(', ')})';
    final rows = await database.query(table,
      columns: keys.contains('rowid') ? ['rowid', '*'] : null,
      where: after == null ? null : '$keyExpression > $cursorExpression',
      whereArgs: after,
      orderBy: keys.join(', '),
      limit: _chunkSize,
    );
    if (rows.isEmpty) return;
    yield rows;
    if (rows.length < _chunkSize) return;
    after = keys.map((key) => rows.last[key]).toList();
  }
}

String _rowKey(Map<String, Object?> row, List<String> keys) => jsonEncode(keys.map((key) => row[key]).toList());

Future<Map<String, Map<String, Object?>>> _matchingRows(DatabaseExecutor database, String table, List<String> keys, List<Map<String, Object?>> rows) async {
  final where = keys.length == 1
      ? '${keys.single} IN (${List.filled(rows.length, '?').join(', ')})'
      : '(${keys.join(', ')}) IN (VALUES ${List.filled(rows.length, '(${List.filled(keys.length, '?').join(', ')})').join(', ')})';
  final matches = await database.query(table,
    where: where,
    whereArgs: rows.expand((row) => keys.map((key) => row[key])).toList(),
    limit: rows.length,
  );
  return {for (final row in matches) _rowKey(row, keys): row};
}
