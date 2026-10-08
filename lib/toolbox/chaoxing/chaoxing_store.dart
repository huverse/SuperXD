import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'package:superxd/toolbox/chaoxing/chaoxing_location.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';

class ChaoxingAccountRecord {
  const ChaoxingAccountRecord({
    required this.phoneNumber,
    required this.uid,
    required this.puid,
    required this.fid,
    required this.name,
    required this.schoolName,
    required this.deviceCode,
    required this.isOtherUser,
    required this.createdAt,
    this.clientId = '',
    this.units = const [],
    this.deviceCodeBound = false,
    this.label = '',
    this.sort = 0,
  });
  final String phoneNumber;
  final int uid;
  final int puid;

  // 所选的学校单位。
  final int fid;
  final String name;

  // 所选学校单位的名字。
  final String schoolName;
  final String deviceCode;
  final bool isOtherUser;
  final DateTime createdAt;

  // 人脸识别签到要用它做设备签名；会话过期重登后才有值。
  final String clientId;

  // 账号挂着的全部学校单位，用户可在其中切换。
  final List<ChaoxingUnit> units;

  // 设备码是否与真实设备一致（本机 OAID 算出的、或对方代签码里带来的）；否则是固定随机码，
  // 本人在官方客户端签过到后再用这里签会被标「更换设备」。
  final bool deviceCodeBound;

  // 手动起的备注名（多账号管理里改），空时显示昵称。
  final String label;

  // 手动排序的位置（多账号管理里拖），小在前；同为 0 时按登录时间倒序。
  final int sort;

  // 显示名：有备注用备注，否则昵称。
  String get displayName => label.isNotEmpty ? label : name;

  ChaoxingAccountRecord change({int? fid, String? schoolName, String? clientId, List<ChaoxingUnit>? units}) => ChaoxingAccountRecord(
    phoneNumber: phoneNumber,
    uid: uid,
    puid: puid,
    fid: fid ?? this.fid,
    name: name,
    schoolName: schoolName ?? this.schoolName,
    deviceCode: deviceCode,
    isOtherUser: isOtherUser,
    createdAt: createdAt,
    clientId: clientId ?? this.clientId,
    units: units ?? this.units,
    deviceCodeBound: deviceCodeBound,
    label: label,
    sort: sort,
  );
}

// 人脸照片：照片本身在学习通云盘，本机只记 objectId、用过几次、有没有被判失败过。
class ChaoxingFaceImage {
  const ChaoxingFaceImage({required this.objectId, required this.useCount, required this.failedBefore});
  final String objectId;
  final int useCount;
  final bool failedBefore;
}

class ChaoxingSavedLocation {
  const ChaoxingSavedLocation({
    required this.id,
    required this.label,
    required this.location,
    required this.updatedAt,
  });
  final int id;
  final String label;
  final ChaoxingLocation location;
  final DateTime updatedAt;
}

// 学习通签到的本机库：账号索引、收藏位置、人脸照片索引、置顶课程、学习通课表缓存与设置。
// 密码与 Cookie 在安全存储里，不在库里。
class ChaoxingStore {
  ChaoxingStore._(this._database);
  final Database _database;
  bool _closed = false;

  // 本人 1 个加他人 20 个；写入新账号前由账号闭环检查，不靠读取时截断。
  static const accountLimit = 21;
  static const locationLimit = 50;
  static const faceImageLimit = 5;
  static const pinnedCourseLimit = 100;

  // 学习通课表缓存 7 天，过期再拉（与学习通客户端同一口径）。
  static const lessonCacheLifetime = Duration(days: 7);

  static Future<ChaoxingStore> open(String path) async {
    final store = ChaoxingStore._(
      await openDatabase(
        path,
        version: 5,
        onCreate: (database, _) async {
          await database.execute(
            'CREATE TABLE accounts (phone_number TEXT PRIMARY KEY, uid INTEGER NOT NULL, puid INTEGER NOT NULL, '
            'fid INTEGER NOT NULL, name TEXT NOT NULL, school_name TEXT NOT NULL, device_code TEXT NOT NULL, '
            'is_other_user INTEGER NOT NULL, created_at INTEGER NOT NULL, client_id TEXT NOT NULL DEFAULT \'\', '
            'units TEXT NOT NULL DEFAULT \'[]\', device_code_bound INTEGER NOT NULL DEFAULT 0, '
            'label TEXT NOT NULL DEFAULT \'\', sort INTEGER NOT NULL DEFAULT 0)',
          );
          await database.execute(
            'CREATE TABLE locations (id INTEGER PRIMARY KEY AUTOINCREMENT, label TEXT NOT NULL, address TEXT NOT NULL, '
            'latitude REAL NOT NULL, longitude REAL NOT NULL, system TEXT NOT NULL, updated_at INTEGER NOT NULL)',
          );
          await database.execute(
            'CREATE INDEX locations_used ON locations (updated_at DESC)',
          );
          await _createFaceTables(database);
          await _addFaceStats(database);
          await _createVersion3Tables(database);
        },
        onUpgrade: (database, oldVersion, _) async {
          if (oldVersion < 2) {
            await database.execute("ALTER TABLE accounts ADD COLUMN client_id TEXT NOT NULL DEFAULT ''");
            await _createFaceTables(database);
          }
          if (oldVersion < 3) {
            await database.execute("ALTER TABLE accounts ADD COLUMN units TEXT NOT NULL DEFAULT '[]'");
            await database.execute('ALTER TABLE accounts ADD COLUMN device_code_bound INTEGER NOT NULL DEFAULT 0');
            await _addFaceStats(database);
            await _createVersion3Tables(database);
          }
          // 第 4 版去掉签到记录：只写不读，参考项目也不在本机留签到历史。
          if (oldVersion < 4) await database.execute('DROP TABLE IF EXISTS sign_records');
          // 第 5 版：账号加备注名与手动排序（多账号管理用）。
          if (oldVersion < 5) {
            await database.execute("ALTER TABLE accounts ADD COLUMN label TEXT NOT NULL DEFAULT ''");
            await database.execute('ALTER TABLE accounts ADD COLUMN sort INTEGER NOT NULL DEFAULT 0');
          }
        },
      ),
    );
    await store._pruneAll();
    return store;
  }

  // 人脸照片只记 objectId（照片本身在学习通的云盘里），每人最多 5 张。
  static Future<void> _createFaceTables(Database database) async {
    await database.execute(
      'CREATE TABLE face_images (id INTEGER PRIMARY KEY AUTOINCREMENT, phone_number TEXT NOT NULL, '
      'object_id TEXT NOT NULL, created_at INTEGER NOT NULL)',
    );
    await database.execute('CREATE INDEX face_images_owner ON face_images (phone_number, id DESC)');
  }

  static Future<void> _addFaceStats(Database database) async {
    await database.execute('ALTER TABLE face_images ADD COLUMN use_count INTEGER NOT NULL DEFAULT 0');
    await database.execute('ALTER TABLE face_images ADD COLUMN failed_before INTEGER NOT NULL DEFAULT 0');
  }

  // 设置（键值）、置顶课程、学习通课表缓存（每个账号一行，整体覆盖）。
  static Future<void> _createVersion3Tables(Database database) async {
    await database.execute('CREATE TABLE preferences (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
    await database.execute(
      'CREATE TABLE pinned_courses (phone_number TEXT NOT NULL, class_id INTEGER NOT NULL, created_at INTEGER NOT NULL, '
      'PRIMARY KEY (phone_number, class_id))',
    );
    await database.execute(
      'CREATE TABLE lesson_cache (phone_number TEXT PRIMARY KEY, payload TEXT NOT NULL, fetched_at INTEGER NOT NULL)',
    );
  }

  // 只增不删的数据都要有上限：打开时整库裁剪一次，之后每次写入只裁剪写到的那张表（或那个账号的那几行）。
  Future<void> _pruneAll() async {
    await _pruneLocations();
    // 学习通课表缓存过期即删（读的时候也按 fetchedAt 判断，这里不让过期的原文一直躺在库里）。
    await _database.delete(
      'lesson_cache',
      where: 'fetched_at < ?',
      whereArgs: [DateTime.now().toUtc().subtract(lessonCacheLifetime).millisecondsSinceEpoch],
    );
    // 每个账号各自留最近几张人脸照片、最近置顶的课程。
    await _database.rawDelete(
      'DELETE FROM face_images WHERE id NOT IN ('
      'SELECT id FROM (SELECT id, ROW_NUMBER() OVER (PARTITION BY phone_number ORDER BY id DESC) AS rank FROM face_images) '
      'WHERE rank <= $faceImageLimit)',
    );
    await _database.rawDelete(
      'DELETE FROM pinned_courses WHERE rowid NOT IN ('
      'SELECT rowid FROM (SELECT rowid, ROW_NUMBER() OVER (PARTITION BY phone_number ORDER BY created_at DESC) AS rank FROM pinned_courses) '
      'WHERE rank <= $pinnedCourseLimit)',
    );
  }

  Future<void> _pruneLocations() => _database.rawDelete(
    'DELETE FROM locations WHERE id NOT IN (SELECT id FROM locations ORDER BY updated_at DESC, id DESC LIMIT $locationLimit)',
  );

  Future<void> _pruneFaceImages(String phoneNumber) => _database.rawDelete(
    'DELETE FROM face_images WHERE phone_number = ? AND id NOT IN '
    '(SELECT id FROM face_images WHERE phone_number = ? ORDER BY id DESC LIMIT $faceImageLimit)',
    [phoneNumber, phoneNumber],
  );

  Future<void> _prunePinnedCourses(String phoneNumber) => _database.rawDelete(
    'DELETE FROM pinned_courses WHERE phone_number = ? AND rowid NOT IN '
    '(SELECT rowid FROM pinned_courses WHERE phone_number = ? ORDER BY created_at DESC LIMIT $pinnedCourseLimit)',
    [phoneNumber, phoneNumber],
  );

  Future<List<ChaoxingAccountRecord>> accounts() async {
    final rows = await _database.query(
      'accounts',
      orderBy: 'is_other_user, sort, created_at DESC',
      limit: accountLimit,
    );
    return rows.map(_account).toList();
  }

  // 备注名（多账号管理里改）。
  Future<void> renameAccount(String phoneNumber, String label) async {
    await _database.update('accounts', {'label': label}, where: 'phone_number = ?', whereArgs: [phoneNumber]);
  }

  // 手动排序：把这次拖完的顺序整体写回（列表小，一次事务里的多条 UPDATE）。
  Future<void> reorderAccounts(List<String> phoneNumbers) async {
    final batch = _database.batch();
    for (var index = 0; index < phoneNumbers.length; index++) {
      batch.update('accounts', {'sort': index}, where: 'phone_number = ?', whereArgs: [phoneNumbers[index]]);
    }
    await batch.commit(noResult: true);
  }

  Future<List<ChaoxingFaceImage>> faceImages(String phoneNumber) async {
    final rows = await _database.query(
      'face_images',
      columns: ['object_id', 'use_count', 'failed_before'],
      where: 'phone_number = ?',
      whereArgs: [phoneNumber],
      orderBy: 'id DESC',
      limit: faceImageLimit,
    );
    return [
      for (final row in rows)
        ChaoxingFaceImage(
          objectId: row['object_id']! as String,
          useCount: row['use_count']! as int,
          failedBefore: (row['failed_before']! as int) == 1,
        ),
    ];
  }

  // 同一个 objectId 只留一条，再存一次把它提到最新（用过的次数与失败标记照旧）。
  Future<void> putFaceImage(String phoneNumber, String objectId) async {
    final existing = await _database.query(
      'face_images',
      columns: ['use_count', 'failed_before'],
      where: 'phone_number = ? AND object_id = ?',
      whereArgs: [phoneNumber, objectId],
      limit: 1,
    );
    await _database.delete('face_images', where: 'phone_number = ? AND object_id = ?', whereArgs: [phoneNumber, objectId]);
    await _database.insert('face_images', {
      'phone_number': phoneNumber,
      'object_id': objectId,
      'created_at': DateTime.now().toUtc().millisecondsSinceEpoch,
      'use_count': existing.isEmpty ? 0 : existing.first['use_count'],
      'failed_before': existing.isEmpty ? 0 : existing.first['failed_before'],
    });
    await _pruneFaceImages(phoneNumber);
  }

  // 每次用这张照片签到后记一次；人脸识别没通过的标上，选照片时提示。
  Future<void> markFaceImageUsed(String phoneNumber, String objectId, {required bool failed}) => _database.rawUpdate(
    'UPDATE face_images SET use_count = use_count + 1, failed_before = MAX(failed_before, ?) WHERE phone_number = ? AND object_id = ?',
    [failed ? 1 : 0, phoneNumber, objectId],
  );

  Future<void> removeFaceImage(String phoneNumber, String objectId) async {
    await _database.delete('face_images', where: 'phone_number = ? AND object_id = ?', whereArgs: [phoneNumber, objectId]);
  }

  Future<String?> preference(String key) async {
    final rows = await _database.query('preferences', columns: ['value'], where: 'key = ?', whereArgs: [key], limit: 1);
    return rows.isEmpty ? null : rows.first['value']! as String;
  }

  Future<void> setPreference(String key, String? value) async {
    if (value == null) {
      await _database.delete('preferences', where: 'key = ?', whereArgs: [key]);
      return;
    }
    await _database.insert('preferences', {'key': key, 'value': value}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Set<int>> pinnedCourses(String phoneNumber) async {
    final rows = await _database.query(
      'pinned_courses',
      columns: ['class_id'],
      where: 'phone_number = ?',
      whereArgs: [phoneNumber],
      limit: pinnedCourseLimit,
    );
    return {for (final row in rows) row['class_id']! as int};
  }

  Future<void> setCoursesPinned(String phoneNumber, Iterable<int> classIds, {required bool pinned}) async {
    final batch = _database.batch();
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    for (final classId in classIds) {
      if (pinned) {
        batch.insert(
          'pinned_courses',
          {'phone_number': phoneNumber, 'class_id': classId, 'created_at': now},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      } else {
        batch.delete('pinned_courses', where: 'phone_number = ? AND class_id = ?', whereArgs: [phoneNumber, classId]);
      }
    }
    await batch.commit(noResult: true);
    await _prunePinnedCourses(phoneNumber);
  }

  // 学习通课表缓存：原样存接口里的 data 段，过期时间由调用方按 fetchedAt 判断。
  Future<({String payload, DateTime fetchedAt})?> lessonCache(String phoneNumber) async {
    final rows = await _database.query('lesson_cache', where: 'phone_number = ?', whereArgs: [phoneNumber], limit: 1);
    if (rows.isEmpty) return null;
    return (
      payload: rows.first['payload']! as String,
      fetchedAt: DateTime.fromMillisecondsSinceEpoch(rows.first['fetched_at']! as int, isUtc: true),
    );
  }

  Future<void> putLessonCache(String phoneNumber, String payload) => _database.insert(
    'lesson_cache',
    {'phone_number': phoneNumber, 'payload': payload, 'fetched_at': DateTime.now().toUtc().millisecondsSinceEpoch},
    conflictAlgorithm: ConflictAlgorithm.replace,
  );

  static ChaoxingAccountRecord _account(Map<String, Object?> row) => ChaoxingAccountRecord(
    phoneNumber: row['phone_number']! as String,
    uid: row['uid']! as int,
    puid: row['puid']! as int,
    fid: row['fid']! as int,
    name: row['name']! as String,
    schoolName: row['school_name']! as String,
    deviceCode: row['device_code']! as String,
    isOtherUser: (row['is_other_user']! as int) == 1,
    createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at']! as int, isUtc: true),
    clientId: '${row['client_id'] ?? ''}',
    units: _units('${row['units'] ?? '[]'}'),
    deviceCodeBound: row['device_code_bound'] == 1,
    label: '${row['label'] ?? ''}',
    sort: row['sort'] == null ? 0 : row['sort']! as int,
  );

  // 库里的 JSON 列按外部输入解析，坏了就当没有。
  static List<ChaoxingUnit> _units(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final item in decoded)
          if (item is Map && item['fid'] is int) ChaoxingUnit(fid: item['fid'] as int, name: '${item['name'] ?? ''}'),
      ];
    } on FormatException {
      return const [];
    }
  }

  Future<void> putAccount(ChaoxingAccountRecord record) => _database.insert(
    'accounts',
    {
      'phone_number': record.phoneNumber,
      'uid': record.uid,
      'puid': record.puid,
      'fid': record.fid,
      'name': record.name,
      'school_name': record.schoolName,
      'device_code': record.deviceCode,
      'is_other_user': record.isOtherUser ? 1 : 0,
      'created_at': record.createdAt.millisecondsSinceEpoch,
      'client_id': record.clientId,
      'units': jsonEncode([for (final unit in record.units) unit.toJson()]),
      'device_code_bound': record.deviceCodeBound ? 1 : 0,
      'label': record.label,
      'sort': record.sort,
    },
    conflictAlgorithm: ConflictAlgorithm.replace,
  );

  // 账号删掉后，它的置顶课程、课表缓存与人脸照片索引一起清掉。
  Future<void> removeAccount(String phoneNumber) async {
    for (final table in ['accounts', 'pinned_courses', 'lesson_cache', 'face_images']) {
      await _database.delete(table, where: 'phone_number = ?', whereArgs: [phoneNumber]);
    }
  }

  Future<List<ChaoxingSavedLocation>> locations() async {
    final rows = await _database.query('locations', orderBy: 'updated_at DESC, id DESC', limit: locationLimit);
    return rows
        .map(
          (row) => ChaoxingSavedLocation(
            id: row['id']! as int,
            label: row['label']! as String,
            location: ChaoxingLocation(
              latitude: (row['latitude']! as num).toDouble(),
              longitude: (row['longitude']! as num).toDouble(),
              address: row['address']! as String,
              system: ChaoxingCoordinateSystem.values.byName(row['system']! as String),
            ),
            updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updated_at']! as int, isUtc: true),
          ),
        )
        .toList();
  }

  // 同标签的位置直接覆盖，避免收藏里堆同一间教室的多条记录。
  Future<void> putLocation(String label, ChaoxingLocation location) async {
    await _database.delete('locations', where: 'label = ?', whereArgs: [label]);
    await _database.insert('locations', {
      'label': label,
      'address': location.address,
      'latitude': location.latitude,
      'longitude': location.longitude,
      'system': location.system.name,
      'updated_at': DateTime.now().toUtc().millisecondsSinceEpoch,
    });
    await _pruneLocations();
  }

  Future<void> removeLocation(int id) async {
    await _database.delete('locations', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> renameLocation(int id, String label) async {
    await _database.update('locations', {'label': label}, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _database.close();
  }
}
