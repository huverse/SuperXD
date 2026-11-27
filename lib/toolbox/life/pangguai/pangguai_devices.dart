import 'dart:convert';
import 'dart:io';

import 'package:synchronized/synchronized.dart';

import 'package:superxd/domain/campus_log.dart';

// 最近用过的一台设备（打开过设备页的）：设备编号、名字、品类与门店名，首页点了直接打开。
class PangguaiDeviceEntry {
  const PangguaiDeviceEntry({required this.goodsId, required this.name, required this.category, required this.place});
  final String goodsId;
  final String name;
  final String category;
  final String place;

  Map<String, Object?> toJson() => {'goodsId': goodsId, 'name': name, 'category': category, 'place': place};
}

const pangguaiRecentLimit = 6;

// 最近使用只存本机（工具目录下的 pangguai_devices.json，按手机号分开），每个账号最多 pangguaiRecentLimit 台，不上传；清除数据时删掉。
// 文件是外部输入：读坏了当没有；整份写到临时文件再改名，写一半不会坏。测试用内存版。
class PangguaiDeviceStore {
  PangguaiDeviceStore._(this._load, this._store);
  final Future<String?> Function() _load;
  // 写整份；为空是删掉。
  final Future<void> Function(String? text) _store;
  final _lock = Lock();

  factory PangguaiDeviceStore.file(File file) => PangguaiDeviceStore._(
    () async => await file.exists() ? await file.readAsString() : null,
    (text) async {
      if (text == null) {
        if (await file.exists()) await file.delete();
        return;
      }
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(text, flush: true);
      await temporary.rename(file.path);
    },
  );

  factory PangguaiDeviceStore.memory() {
    String? saved;
    return PangguaiDeviceStore._(() async => saved, (text) async => saved = text);
  }

  Future<Map<String, Object?>> _read() async {
    try {
      final text = await _load();
      if (text == null) return {};
      final json = jsonDecode(text);
      return json is Map ? json.cast<String, Object?>() : {};
    } catch (error, stack) {
      campusLog('[Pangguai] action=devices_read errorType=${error.runtimeType}\n$stack');
      return {};
    }
  }

  Future<List<PangguaiDeviceEntry>> recent(String phone) async {
    final raw = (await _read())[phone];
    return [
      if (raw is List)
        for (final item in raw)
          if (item is Map && item['goodsId'] is String && item['name'] is String && item['category'] is String && item['place'] is String)
            PangguaiDeviceEntry(goodsId: item['goodsId'] as String, name: item['name'] as String, category: item['category'] as String, place: item['place'] as String),
    ].take(pangguaiRecentLimit).toList();
  }

  // 打开过的设备记到最前面，同一台只留一份。
  Future<void> used(String phone, PangguaiDeviceEntry entry) => _lock.synchronized(() async {
    final list = [entry, ...(await recent(phone)).where((item) => item.goodsId != entry.goodsId)].take(pangguaiRecentLimit);
    final all = await _read();
    all[phone] = [for (final item in list) item.toJson()];
    await _store(jsonEncode(all));
  });

  // 退出账号时删掉它的最近使用。
  Future<void> forget(String phone) => _lock.synchronized(() async {
    final all = await _read();
    if (all.remove(phone) != null) await _store(jsonEncode(all));
  });

  Future<void> deleteAll() => _lock.synchronized(() => _store(null));
}
