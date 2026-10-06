import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:superxd/toolbox/chaoxing/chaoxing_location.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_store.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_vault.dart';

ChaoxingAccountRecord _account(String phoneNumber, {bool isOtherUser = false}) => ChaoxingAccountRecord(
  phoneNumber: phoneNumber,
  uid: 1,
  puid: 2,
  fid: 3,
  name: '同学$phoneNumber',
  schoolName: '示例大学',
  deviceCode: 'device-$phoneNumber',
  isOtherUser: isOtherUser,
  createdAt: DateTime.now().toUtc(),
);

ChaoxingSignRecord _record({DateTime? createdAt}) => ChaoxingSignRecord(
  phoneNumber: '13800138000',
  activeId: 1,
  courseId: 2,
  signType: ChaoxingSignType.password,
  result: 'success',
  createdAt: createdAt ?? DateTime.now().toUtc(),
);

void main() {
  late Directory directory;
  late ChaoxingStore store;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final root = await Directory(
      path.join(Directory.current.path, 'build', 'chaoxing_tests'),
    ).create(recursive: true);
    directory = await root.createTemp('case_');
    store = await ChaoxingStore.open(path.join(directory.path, 'chaoxing.db'));
  });

  tearDown(() async {
    await store.close();
    await directory.delete(recursive: true);
  });

  test('账号索引只存账号信息，本人账号排在前面', () async {
    await store.putAccount(_account('139', isOtherUser: true));
    await store.putAccount(_account('138'));
    final accounts = await store.accounts();
    expect(accounts.map((item) => item.phoneNumber), ['138', '139']);
    expect(accounts.first.deviceCode, 'device-138');
    expect(accounts.first.isOtherUser, isFalse);

    await store.putAccount(_account('138'));
    expect((await store.accounts()).length, 2);

    await store.removeAccount('138');
    expect((await store.accounts()).map((item) => item.phoneNumber), ['139']);
  });

  test('收藏位置同标签覆盖，并按最近使用裁剪到上限', () async {
    for (var index = 0; index < ChaoxingStore.locationLimit + 5; index++) {
      await store.putLocation(
        '教室$index',
        ChaoxingLocation(latitude: 39.9 + index / 1000, longitude: 116.4, address: '教学楼$index'),
      );
    }
    final locations = await store.locations();
    expect(locations.length, ChaoxingStore.locationLimit);
    expect(locations.first.label, '教室54');

    await store.putLocation('教室54', const ChaoxingLocation(latitude: 30.1, longitude: 120.2, address: '新教室'));
    final updated = await store.locations();
    expect(updated.length, ChaoxingStore.locationLimit);
    expect(updated.first.location.latitude, 30.1);
    expect(updated.first.location.system, ChaoxingCoordinateSystem.bd09);
  });

  test('签到记录只增不删有上限，超期与超量都会裁剪', () async {
    await store.addSignRecord(_record(createdAt: DateTime.now().toUtc().subtract(const Duration(days: 120))));
    await store.addSignRecord(_record());
    expect((await store.signRecords()).length, 1);

    for (var index = 0; index < ChaoxingStore.signRecordLimit + 10; index++) {
      await store.addSignRecord(_record());
    }
    expect((await store.signRecords(limit: ChaoxingStore.signRecordLimit + 100)).length, ChaoxingStore.signRecordLimit);
  });

  test('安全存储里读写账号密码与 Cookie', () async {
    final vault = MemoryChaoxingVault();
    expect(await vault.readPassword('138'), isNull);
    await vault.writePassword('138', 'cipher');
    await vault.writeCookies('138', {'_uid': '1'});
    expect(await vault.readPassword('138'), 'cipher');
    expect(await vault.readCookies('138'), {'_uid': '1'});
    await vault.delete('138');
    expect(await vault.readPassword('138'), isNull);
    expect(await vault.readCookies('138'), isNull);
  });
}
