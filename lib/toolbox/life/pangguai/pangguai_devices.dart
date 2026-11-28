import 'dart:convert';
import 'dart:io';

import 'package:synchronized/synchronized.dart';

import 'package:superxd/domain/campus_log.dart';

// 扫到的码里认出的设备：key 是交给胖乖扫码接口的参数名（NQT、IMEI、SN），water 是饮水机（apwork.cn 码 ? 后面的 32 位十六进制，同官方）。
// 认 h5.qiekj.com 或 qiekj.com 链接里的 NQT、IMEI、SN，单独的 NQT（UUID 写法）与单独的 32 位十六进制；别的码一律不认（不对任意链接跳转、不追加凭据）。
typedef PangguaiCode = ({String key, String value});

final _waterHash = RegExp(r'^[0-9A-Fa-f]{32}$');
final _uuid = RegExp(r'^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$');

PangguaiCode? pangguaiParseCode(String raw) {
  final text = raw.trim();
  if (_waterHash.hasMatch(text)) return (key: 'water', value: text);
  if (_uuid.hasMatch(text)) return (key: 'NQT', value: text);
  final uri = Uri.tryParse(text);
  if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) return null;
  if (uri.host == 'apwork.cn') return _waterHash.hasMatch(uri.query) ? (key: 'water', value: uri.query) : null;
  if (uri.host != 'h5.qiekj.com' && uri.host != 'qiekj.com') return null;
  final Map<String, String> query;
  try {
    query = uri.queryParameters;
  } on FormatException {
    return null;
  }
  for (final key in const ['NQT', 'IMEI', 'SN']) {
    final value = query[key]?.trim();
    if (value != null && RegExp(r'^[0-9A-Za-z\-_]{1,64}$').hasMatch(value)) return (key: key, value: value);
  }
  return null;
}

// 本机记着的一台用过的设备：先付后用的记设备号 goodsId 与品类（列表里按品类画图标），饮水机记码里的设备号；名字与位置（门店、楼）给人认。
class PangguaiDeviceEntry {
  const PangguaiDeviceEntry({required this.water, required this.id, required this.name, required this.place, this.category = ''});
  final bool water;
  final String id;
  final String name;
  final String place;
  final String category;

  Map<String, Object> toJson() => {'water': water, 'id': id, 'name': name, 'place': place, 'category': category};
}

// 每个账号最近用过的设备最多记这么多台，新的在前。
const pangguaiRecentLimit = 6;

// 最近使用只存本机（工具目录下的 pangguai_devices.json，按手机号分开），不上传；清除数据时删掉。
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

  Future<List<PangguaiDeviceEntry>> load(String phone) async {
    final raw = (await _read())[phone];
    return [
      if (raw is List)
        for (final item in raw)
          if (item is Map && item['water'] is bool && item['id'] is String && item['name'] is String && item['place'] is String)
            PangguaiDeviceEntry(water: item['water'] as bool, id: item['id'] as String, name: item['name'] as String, place: item['place'] as String, category: item['category'] is String ? item['category'] as String : ''),
    ].take(pangguaiRecentLimit).toList();
  }

  // 打开过设备页的设备记到最前面，同一台只留一份。
  Future<List<PangguaiDeviceEntry>> used(String phone, PangguaiDeviceEntry entry) => _lock.synchronized(() async {
    final recent = [entry, ...(await load(phone)).where((item) => item.water != entry.water || item.id != entry.id)].take(pangguaiRecentLimit).toList();
    final all = await _read();
    all[phone] = [for (final item in recent) item.toJson()];
    await _store(jsonEncode(all));
    return recent;
  });

  Future<void> deleteAll() => _lock.synchronized(() => _store(null));
}
