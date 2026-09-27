import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import 'package:superxd/gateway/account_access.dart';
import 'package:superxd/local/app_database.dart';

class AccountStore {
  AccountStore._(this._index, this._directory);

  final Database _index;
  final String _directory;

  static Future<AccountStore> open({String? directory}) async {
    final root = path.normalize(path.absolute(directory ?? await getDatabasesPath()));
    await Directory(root).create(recursive: true);
    final index = await openDatabase(path.join(root, 'account_index.db'), version: 1, singleInstance: false,
      onCreate: (db, version) async {
        await db.execute('''
CREATE TABLE account (
  account_key TEXT PRIMARY KEY,
  source TEXT NOT NULL,
  login_id TEXT NOT NULL,
  display_name TEXT NOT NULL DEFAULT '',
  legacy_deferred INTEGER NOT NULL DEFAULT 0
)''');
        await db.execute('''
CREATE TABLE active_account (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  account_key TEXT NOT NULL
)''');
        await db.execute('''
CREATE TABLE legacy_claim (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  legacy_key TEXT NOT NULL,
  account_key TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('claimed', 'done'))
)''');
      },
    );
    return AccountStore._(index, root);
  }

  // URL 保留校园部署的 base path；端口、大小写和末尾斜线的等价写法共用账号库。
  AccountIdentity _normalize(AccountIdentity identity) {
    final source = Uri.parse(identity.source.trim()).normalizePath();
    if ((source.scheme != 'http' && source.scheme != 'https') || source.host.isEmpty || source.userInfo.isNotEmpty || source.hasQuery || source.hasFragment) {
      throw ArgumentError.value(identity.source, 'source', '教务来源必须是无凭据、查询或片段的 HTTP(S) base URL');
    }
    final loginId = identity.loginId.trim();
    if (loginId.isEmpty) throw ArgumentError.value(identity.loginId, 'loginId', '必须使用教务确认的非空账号');
    final basePath = source.path.replaceFirst(RegExp(r'/+$'), '');
    return AccountIdentity(source: '${source.origin}$basePath', loginId: loginId);
  }

  String keyOf(AccountIdentity identity) {
    final normalized = _normalize(identity);
    return sha256.convert(utf8.encode(jsonEncode([normalized.source, normalized.loginId]))).toString();
  }

  String get _legacyPath => path.join(_directory, 'superxd.db');
  String get _legacyKey => 'superxd.db';

  Future<AccountIdentity?> currentIdentity() async {
    final rows = await _index.rawQuery('''
SELECT account.source, account.login_id FROM active_account
JOIN account ON account.account_key = active_account.account_key
WHERE active_account.id = 1 LIMIT 1
''');
    if (rows.isEmpty) return null;
    return AccountIdentity(source: rows.single['source'] as String, loginId: rows.single['login_id'] as String);
  }

  Future<void> activate(AccountIdentity identity, {String displayName = ''}) async {
    final normalized = _normalize(identity);
    final key = keyOf(normalized);
    await _index.transaction((transaction) async {
      await transaction.rawInsert('''
INSERT INTO account (account_key, source, login_id, display_name) VALUES (?, ?, ?, ?)
ON CONFLICT(account_key) DO UPDATE SET display_name = excluded.display_name
''', [key, normalized.source, normalized.loginId, displayName]);
      await transaction.insert('active_account', {'id': 1, 'account_key': key}, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  Future<void> clearCurrent() async {
    await _index.delete('active_account', where: 'id = 1');
  }

  // [人工决策-2026-09-24 21:10:42] 来源与教务确认账号共同归属独立库；切换保留数据，不认领无owner旧库。
  Future<AppDatabase> openAccount(AccountIdentity identity) async {
    final normalized = _normalize(identity);
    final directory = path.join(_directory, 'accounts');
    await Directory(directory).create(recursive: true);
    return AppDatabase.openForAccount(databasePath: path.join(directory, '${keyOf(normalized)}.db'), identity: normalized);
  }

  Future<LegacyImportState> legacyState(AccountIdentity identity) async {
    final key = keyOf(identity);
    final claim = await _index.query('legacy_claim', where: 'id = 1', limit: 1);
    if (claim.isNotEmpty) {
      if (claim.single['account_key'] != key || claim.single['status'] == 'done') return const LegacyImportState(available: false);
      return const LegacyImportState(available: true, resumable: true);
    }
    final account = await _index.query('account', columns: ['legacy_deferred'], where: 'account_key = ?', whereArgs: [key], limit: 1);
    return LegacyImportState(available: await File(_legacyPath).exists(), deferred: account.firstOrNull?['legacy_deferred'] == 1);
  }

  Future<void> deferLegacy(AccountIdentity identity) async {
    final normalized = _normalize(identity);
    await _index.rawInsert('''
INSERT INTO account (account_key, source, login_id, legacy_deferred) VALUES (?, ?, ?, 1)
ON CONFLICT(account_key) DO UPDATE SET legacy_deferred = 1
''', [keyOf(normalized), normalized.source, normalized.loginId]);
  }

  Future<LegacyImportReport> importLegacy(AccountIdentity identity, AppDatabase target) async {
    final normalized = _normalize(identity);
    final key = keyOf(normalized);
    if (path.normalize(target.databasePath) != path.join(_directory, 'accounts', '$key.db')) throw StateError('导入目标不是该账号的数据库');
    await target.verifyOwner(normalized);
    // [人工决策-2026-09-24 21:10:42] 用户确认旧数据属于当前账号后仅认领一次；不导入旧session，不覆盖目标数据。
    // 认领先提交，目标数据及完成标记一起提交，最后更新索引完成状态。
    await _index.transaction((transaction) async {
      final claim = await transaction.query('legacy_claim', where: 'id = 1', limit: 1);
      if (claim.isNotEmpty) {
        if (claim.single['account_key'] != key || claim.single['legacy_key'] != _legacyKey) throw StateError('旧数据库已由其他账号认领');
        return;
      }
      if (!await File(_legacyPath).exists()) throw StateError('旧数据库不存在');
      await transaction.insert('legacy_claim', {'id': 1, 'legacy_key': _legacyKey, 'account_key': key, 'status': 'claimed'});
    });
    final existing = await target.legacyImportReport(_legacyKey);
    final LegacyImportReport report;
    if (existing == null) {
      if (!await File(_legacyPath).exists()) throw StateError('已认领的旧数据库不存在，无法继续导入');
      final legacy = await openReadOnlyDatabase(_legacyPath, singleInstance: false);
      try {
        report = await legacy.transaction((snapshot) => target.importLegacyRows(snapshot, legacyKey: _legacyKey, identity: normalized), exclusive: false);
      } finally {
        await legacy.close();
      }
    } else {
      report = existing;
    }
    await _index.update('legacy_claim', {'status': 'done'}, where: 'id = 1 AND account_key = ? AND legacy_key = ?', whereArgs: [key, _legacyKey]);
    return report;
  }

  // 账号库句柄由账号生命周期门面持有并关闭；索引不代持业务数据库连接。
  Future<void> close() => _index.close();
}
