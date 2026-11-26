import 'dart:convert';
import 'dart:io';

import 'package:synchronized/synchronized.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_models.dart';

// 扫到的码里认出的设备（同原 App 的 Zi，资料 4.1.1）：住理域名的链接带 d（设备号）或 mac，「12 位十六进制-设备号」，纯 12 位十六进制（蓝牙地址）。
// 别的码（卡号、转账、收银台、别的网址）都不认，返回空。
typedef ZhuliCode = ({int? deviceId, String? mac});

const _codeHosts = {'zhuli.whxinna.com', 'alipay-zhuli.whxinna.com', 'wechat-zhuli.whxinna.com', 'uc-zhuli.whxinna.com'};

ZhuliCode? zhuliParseCode(String raw) {
  final text = raw.trim();
  final uri = Uri.tryParse(text);
  if (uri != null && (uri.scheme == 'https' || uri.scheme == 'http') && _codeHosts.contains(uri.host)) {
    // 查询串可能在 # 后面（原 App 把 search 与 hash 里的都读）。
    final query = {...uri.queryParameters, ...Uri.splitQueryString(uri.fragment.contains('?') ? uri.fragment.substring(uri.fragment.indexOf('?') + 1) : uri.fragment.contains('=') ? uri.fragment : '')};
    // # 后面整段先当设备号，查询串里的 d 再盖过它（原 App 的 Zi：t.d = hash.slice(1)；资料表格只写了 ?d=）。
    // 设备屏幕上的码就是「https://zhuli.whxinna.com/#设备号」，11-26 用户真机扫了说不是设备码（照片解出来是这个写法）。
    final deviceId = int.tryParse(query['d'] ?? uri.fragment), mac = zhuliMac(query['mac'] ?? '');
    return deviceId == null && mac == null ? null : (deviceId: deviceId, mac: mac);
  }
  if (RegExp(r'^([0-9A-Fa-f]{12})-(\d{1,12})$').firstMatch(text) case final match?) return (deviceId: int.parse(match[2]!), mac: zhuliMac(match[1]!));
  if (zhuliMac(text) case final mac?) return (deviceId: null, mac: mac);
  return null;
}

// 蓝牙地址写成住理认的冒号格式（0A:1B:2C:3D:4E:5F；资料实测横线分隔与纯十六进制都回 device_not_exists）。
String? zhuliMac(String text) {
  final hex = text.replaceAll(RegExp(r'[:\-]'), '');
  if (!RegExp(r'^[0-9A-Fa-f]{12}$').hasMatch(hex)) return null;
  return [for (var index = 0; index < 12; index += 2) hex.substring(index, index + 2)].join(':').toUpperCase();
}

// 本机记着的一台设备：设备号、名字与位置（1号楼 2层 201），列表里给人认。
class ZhuliDeviceEntry {
  const ZhuliDeviceEntry({required this.id, required this.name, required this.place, this.mode, this.channel});
  final int id;
  final String name;
  final String place;
  // 设备有哪几路（ZhuliDevice.modeLabel：云端、蓝牙或云端/蓝牙），列表里和设备号一起写，免得同房间同名的设备分不清；11-23 以前记的没有。
  final String? mode;
  // 两用设备上次选的通道（4 蓝牙，其余是云端的通道号），下次打开默认用它；没选过为空。
  final int? channel;

  factory ZhuliDeviceEntry.of(ZhuliDevice device) => ZhuliDeviceEntry(id: device.id, name: device.distinctName ?? '', place: device.place, mode: device.modeLabel);

  // 列表里的一行说明：设备号、和房间不同的设备名、有哪几路。
  String get detail => [if (name.isNotEmpty && !place.endsWith(name)) name, '设备号 $id', ?mode].join(' · ');

  ZhuliDeviceEntry merged(ZhuliDeviceEntry? known) => ZhuliDeviceEntry(id: id, name: name, place: place, mode: mode ?? known?.mode, channel: channel ?? known?.channel);

  Map<String, Object> toJson() => {'id': id, 'name': name, 'place': place, 'mode': ?mode, 'channel': ?channel};
}

// 一个账号的两份设备列表（用户 11-22 选「两份」）：最近使用自动记，最多 zhuliRecentLimit 台、新的在前；
// 常用设备自己收藏（设备页的星标、扫码或输设备号加），最多 zhuliFavoriteLimit 台，按用户排的顺序（可置顶）。
typedef ZhuliDeviceLists = ({List<ZhuliDeviceEntry> recent, List<ZhuliDeviceEntry> favorites});

const zhuliRecentLimit = 6;
const zhuliFavoriteLimit = 20;

// 设备列表只存本机（工具目录下的 zhuli_devices.json，按手机号分开，同原 App 按手机号存），不上传；清除数据时删掉。
// 文件是外部输入：读坏了当没有；整份写到临时文件再改名，写一半不会坏。测试用内存版。
class ZhuliDeviceStore {
  ZhuliDeviceStore._(this._load, this._store);
  final Future<String?> Function() _load;
  // 写整份；为空是删掉。
  final Future<void> Function(String? text) _store;
  // 读改写一次只做一件。
  final _lock = Lock();

  factory ZhuliDeviceStore.file(File file) => ZhuliDeviceStore._(
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

  factory ZhuliDeviceStore.memory() {
    String? saved;
    return ZhuliDeviceStore._(() async => saved, (text) async => saved = text);
  }

  Future<Map<String, Object?>> _read() async {
    try {
      final text = await _load();
      if (text == null) return {};
      final json = jsonDecode(text);
      return json is Map ? json.cast<String, Object?>() : {};
    } catch (error, stack) {
      campusLog('[Zhuli] action=devices_read errorType=${error.runtimeType}\n$stack');
      return {};
    }
  }

  static List<ZhuliDeviceEntry> _entries(Object? raw, int limit) => [
    if (raw is List)
      for (final item in raw)
        if (item is Map && item['id'] is int && item['name'] is String && item['place'] is String)
          ZhuliDeviceEntry(
            id: item['id'] as int,
            name: item['name'] as String,
            place: item['place'] as String,
            mode: item['mode'] is String ? item['mode'] as String : null,
            channel: item['channel'] is int ? item['channel'] as int : null,
          ),
  ].take(limit).toList();

  Future<ZhuliDeviceLists> load(String phone) async {
    final account = (await _read())[phone];
    final json = account is Map ? account : const <String, Object?>{};
    return (recent: _entries(json['recent'], zhuliRecentLimit), favorites: _entries(json['favorites'], zhuliFavoriteLimit));
  }

  Future<ZhuliDeviceLists> _save(String phone, ZhuliDeviceLists lists) async {
    final all = await _read();
    all[phone] = {'recent': [for (final entry in lists.recent) entry.toJson()], 'favorites': [for (final entry in lists.favorites) entry.toJson()]};
    await _store(jsonEncode(all));
    return lists;
  }

  // 用过（打开过设备页）的设备记到最近使用最前面，同一台只留一份；常用设备里有这台就原位更新名字、位置与有哪几路。上次选的通道留着。
  Future<ZhuliDeviceLists> used(String phone, ZhuliDeviceEntry entry) => _lock.synchronized(() async {
    final lists = await load(phone);
    ZhuliDeviceEntry? known(List<ZhuliDeviceEntry> list) => list.where((item) => item.id == entry.id).firstOrNull;
    final fresh = entry.merged(known(lists.recent) ?? known(lists.favorites));
    return _save(phone, (
      recent: [fresh, ...lists.recent.where((item) => item.id != entry.id)].take(zhuliRecentLimit).toList(),
      favorites: [for (final item in lists.favorites) item.id == entry.id ? entry.merged(item) : item],
    ));
  });

  // 两用设备选了走哪一路：最近使用与常用设备里这台都记下，下次默认用它。
  Future<ZhuliDeviceLists> prefer(String phone, int deviceId, int channel) => _lock.synchronized(() async {
    final lists = await load(phone);
    ZhuliDeviceEntry pick(ZhuliDeviceEntry item) => item.id == deviceId ? ZhuliDeviceEntry(id: item.id, name: item.name, place: item.place, mode: item.mode, channel: channel) : item;
    return _save(phone, (recent: [for (final item in lists.recent) pick(item)], favorites: [for (final item in lists.favorites) pick(item)]));
  });

  // 收藏（已收藏的不动位置，满了抛 StateError，页面先看数量）。
  Future<ZhuliDeviceLists> favor(String phone, ZhuliDeviceEntry entry) => _lock.synchronized(() async {
    final lists = await load(phone);
    if (lists.favorites.any((known) => known.id == entry.id)) return lists;
    if (lists.favorites.length >= zhuliFavoriteLimit) throw StateError('favorites full');
    return _save(phone, (recent: lists.recent, favorites: [...lists.favorites, entry.merged(lists.recent.where((item) => item.id == entry.id).firstOrNull)]));
  });

  Future<ZhuliDeviceLists> unfavor(String phone, int deviceId) => _lock.synchronized(() async {
    final lists = await load(phone);
    return _save(phone, (recent: lists.recent, favorites: [for (final known in lists.favorites) if (known.id != deviceId) known]));
  });

  Future<ZhuliDeviceLists> pin(String phone, int deviceId) => _lock.synchronized(() async {
    final lists = await load(phone);
    final entry = lists.favorites.where((known) => known.id == deviceId).firstOrNull;
    if (entry == null) return lists;
    return _save(phone, (recent: lists.recent, favorites: [entry, ...lists.favorites.where((known) => known.id != deviceId)]));
  });

  Future<void> deleteAll() => _lock.synchronized(() => _store(null));
}
