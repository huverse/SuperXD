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
  });
  final String phoneNumber;
  final int uid;
  final int puid;
  final int fid;
  final String name;
  final String schoolName;
  final String deviceCode;
  final bool isOtherUser;
  final DateTime createdAt;
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

class ChaoxingSignRecord {
  const ChaoxingSignRecord({
    required this.phoneNumber,
    required this.activeId,
    required this.courseId,
    required this.signType,
    required this.result,
    required this.createdAt,
  });
  final String phoneNumber;
  final int activeId;
  final int courseId;
  final ChaoxingSignType signType;
  final String result;
  final DateTime createdAt;
}

// 学习通签到的本机库：账号索引、收藏位置与签到记录。密码与 Cookie 在安全存储里，不在库里。
class ChaoxingStore {
  ChaoxingStore._(this._database);
  final Database _database;
  bool _closed = false;

  static const accountLimit = 21;
  static const locationLimit = 50;
  static const signRecordLimit = 500;
  static const signRecordRetention = Duration(days: 90);

  static Future<ChaoxingStore> open(String path) async {
    final store = ChaoxingStore._(
      await openDatabase(
        path,
        version: 1,
        onCreate: (database, _) async {
          await database.execute(
            'CREATE TABLE accounts (phone_number TEXT PRIMARY KEY, uid INTEGER NOT NULL, puid INTEGER NOT NULL, '
            'fid INTEGER NOT NULL, name TEXT NOT NULL, school_name TEXT NOT NULL, device_code TEXT NOT NULL, '
            'is_other_user INTEGER NOT NULL, created_at INTEGER NOT NULL)',
          );
          await database.execute(
            'CREATE TABLE locations (id INTEGER PRIMARY KEY AUTOINCREMENT, label TEXT NOT NULL, address TEXT NOT NULL, '
            'latitude REAL NOT NULL, longitude REAL NOT NULL, system TEXT NOT NULL, updated_at INTEGER NOT NULL)',
          );
          await database.execute(
            'CREATE INDEX locations_used ON locations (updated_at DESC)',
          );
          await database.execute(
            'CREATE TABLE sign_records (id INTEGER PRIMARY KEY AUTOINCREMENT, phone_number TEXT NOT NULL, '
            'active_id INTEGER NOT NULL, course_id INTEGER NOT NULL, sign_type TEXT NOT NULL, result TEXT NOT NULL, '
            'created_at INTEGER NOT NULL)',
          );
          await database.execute(
            'CREATE INDEX sign_records_time ON sign_records (created_at DESC, id DESC)',
          );
        },
      ),
    );
    await store.prune();
    return store;
  }

  // 只增不删的数据都要有上限：账号、收藏位置与签到记录在每次打开时裁剪。
  Future<void> prune() async {
    await _database.delete(
      'sign_records',
      where: 'created_at < ?',
      whereArgs: [
        DateTime.now().toUtc().subtract(signRecordRetention).millisecondsSinceEpoch,
      ],
    );
    await _database.rawDelete(
      'DELETE FROM sign_records WHERE id NOT IN (SELECT id FROM sign_records ORDER BY created_at DESC, id DESC LIMIT $signRecordLimit)',
    );
    await _database.rawDelete(
      'DELETE FROM locations WHERE id NOT IN (SELECT id FROM locations ORDER BY updated_at DESC, id DESC LIMIT $locationLimit)',
    );
  }

  Future<List<ChaoxingAccountRecord>> accounts() async {
    final rows = await _database.query(
      'accounts',
      orderBy: 'is_other_user, created_at DESC',
      limit: accountLimit,
    );
    return rows.map(_account).toList();
  }

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
  );

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
    },
    conflictAlgorithm: ConflictAlgorithm.replace,
  );

  Future<void> removeAccount(String phoneNumber) async {
    await _database.delete('accounts', where: 'phone_number = ?', whereArgs: [phoneNumber]);
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
    await prune();
  }

  Future<void> removeLocation(int id) async {
    await _database.delete('locations', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> addSignRecord(ChaoxingSignRecord record) async {
    await _database.insert('sign_records', {
      'phone_number': record.phoneNumber,
      'active_id': record.activeId,
      'course_id': record.courseId,
      'sign_type': record.signType.name,
      'result': record.result,
      'created_at': record.createdAt.millisecondsSinceEpoch,
    });
    await prune();
  }

  Future<List<ChaoxingSignRecord>> signRecords({int limit = 100}) async {
    final rows = await _database.query(
      'sign_records',
      orderBy: 'created_at DESC, id DESC',
      limit: limit,
    );
    return rows
        .map(
          (row) => ChaoxingSignRecord(
            phoneNumber: row['phone_number']! as String,
            activeId: row['active_id']! as int,
            courseId: row['course_id']! as int,
            signType: ChaoxingSignType.values.byName(row['sign_type']! as String),
            result: row['result']! as String,
            createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at']! as int, isUtc: true),
          ),
        )
        .toList();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _database.close();
  }
}
