import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:superxd/theme/campus_segmented.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/dot_separated_text.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_bath.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_bath_page.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_ble.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_client.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_devices.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_http.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_models.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_page.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_pick_page.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_protocol.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_service.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_vault.dart';
import 'package:superxd/toolbox/toolbox_catalog.dart';
import 'package:superxd/toolbox/toolbox_module.dart';
import 'package:superxd/toolbox/toolbox_runtime.dart';

import 'text_fit_support.dart';
import 'toolbox_test_support.dart';

// 住理生活第二轮：洗浴（人工决策见 lib/toolbox/life/zhuli/zhuli_service.dart 文件头）。设备、楼栋与蓝牙帧全是合成的。

const _phone = '13800000001', _password = '123456';

// 一帧：第 3 个字节是命令类型，其余补零（20 字节）。
String _frame(int command, [int marker = 0]) => '0000${command.toRadixString(16).padLeft(2, '0')}${marker.toRadixString(16).padLeft(2, '0')}${'00' * 16}'.toUpperCase();

Map<String, Object?> _device(int id, {String module = '4,6', int status = 0, int consume = 1, int group = 0, String? supply, Object? change}) => {
  'device_id': id,
  'device_name': '201',
  'device_type': 0,
  'net_type': module == '4' ? 4 : 64,
  'net_module': module,
  'status': status,
  'consume_status': consume,
  'group_id': group,
  'primary_consume_net_type': null,
  'change_network': change,
  'water_supply_time': supply,
  'building_name': '1号楼',
  'floor_name': '2',
  'room_name': '201',
  'ble_name': 'XN-$id',
  'ble_mac': '40:BD:32:00:00:${id.toRadixString(16).padLeft(2, '0').toUpperCase()}',
};

// 假住理：登录、账户与计费规则、券、配置、设备与楼栋、下单与关水、蓝牙命令帧；记下每次请求。
class _FakeBath {
  final requests = <Uri>[];
  final valid = <String>{};
  var counter = 0;
  Map<String, Object?> config = {'bath_enable': 1, 'minimum_consume_balance': 0.0, 'continue_use_on_min_consume_balance_enabled': 0, 'force_supply_time': 0};
  final devices = <int, Map<String, Object?>>{101: _device(101), 102: _device(102, module: '4')};
  var pending = <Object>[];
  Map<String, Object?>? last;
  var billStatus = 'created';
  // 开着水时住理给不给用量（11-22 真机上云端设备不给，关水才回来）。
  var liveUsage = true;
  var occupied = false;
  // 握手后补传的历史单就把这一单结算了（在设备上关了水）。
  var historySettles = false;
  // 这一路径下一次回 login_timeout（模拟洗着澡会话过期）。
  String? expireOn;

  int count(String path) => requests.where((uri) => uri.path == path).length;
  Map<String, String> lastQuery(String path) => requests.lastWhere((uri) => uri.path == path).queryParameters;

  late final client = MockClient((request) async {
    requests.add(request.url);
    final query = request.url.queryParameters;
    // 同真实服务端：data 一律 base64，命令帧是 base64 包着的十六进制串（不套 JSON）。
    Map<String, Object?> ok(Object? data) => {'result': true, 'data': zhuliBase64(data is String ? data : jsonEncode(data))};
    Map<String, Object?> fail(String? code, [String? message]) => {'result': false, 'err_msg': code, 'msg': message, 'data': null};
    final Map<String, Object?> reply;
    if (request.url.host == 'pm.whxinna.com') {
      final identity = 'ID${++counter}';
      valid.add(identity);
      reply = ok({
        'user_info': {'id': 'U1', 'identity_code': identity},
        'server_info': {'server_addr': 'https://zhuli999.whxinna.com', 'server_appid': 1, 'server_id': 2, 'session_secret': 'S$counter', 'projectname': '合成学院'},
      });
    } else if (!valid.contains(query['identitycode']) || expireOn == request.url.path) {
      if (expireOn == request.url.path) {
        expireOn = null;
        valid.clear();
      }
      reply = fail('login_timeout');
    } else {
      reply = switch (request.url.path) {
        '/webapi/v1/staff/get_user_detail_by_id' => ok({
          'balance': '17.4900',
          'frozen_balance': 0.0,
          'cash_coupon_count': 1,
          'ChargeRules': [
            {'device_type': 0, 'device_group_id': 0, 'charge_option': 'metering', 'charge_money': 5.0, 'charge_units': [{'price': 0.07, 'value': 1}]},
          ],
        }),
        '/webapi/v1/cash_coupon/list_staff_cash_coupon_app' => ok(query['is_blance'] == '1' ? {'rows': [{'id': 'Q1', 'cash_coupon_name': '合成券', 'balance': 176.35, 'total_money': 280.0}], 'total_count': 1} : {'rows': <Object>[], 'total_count': 0}),
        '/webapi/v1/app_setting/get_config' => ok(config),
        '/webapi/v1/staff/query_pending_order' => ok(pending),
        '/webapi/v1/consume/get_staff_last_record' => ok(last),
        '/webapi/v1/device/get_by_id' => switch (devices[int.parse(query['id']!)]) {
          final device? => ok(device),
          null => fail('device_not_exists'),
        },
        '/webapi/v1/device/get_by_mac' => switch (devices.values.where((device) => device['ble_mac'] == query['mac']).firstOrNull) {
          final device? => ok(device),
          null => fail('device_not_exists'),
        },
        '/webapi/v1/building/list_onlybuilding' => ok([{'id': 'B1', 'name': '1号楼', 'device_count': {'normal_count': 2.0, 'total_count': 280.0, 'unnormal_count': 5.0}}]),
        '/webapi/v1/building/list_floors' => ok([{'id': 'F2', 'building_id': 'B1', 'name': '2', 'room_count': 2}]),
        '/webapi/v1/building/list_rooms' => ok([
          {'id': 'R0', 'name': '200', 'device_count': {'normal_count': 0, 'total_room_device_count': 0}},
          {'id': 'R1', 'name': '201', 'device_count': {'normal_count': 0, 'total_room_device_count': 2}},
        ]),
        '/webapi/v1/device/list_room_device_by_consume_type' => ok(devices.values.toList()),
        '/webapi/v1/device/collect_gprs_device_status' => ok(null),
        '/webapi/v1/consume/create_order' => ok({'order_id': 'O1', 'status': 'created', 'balance': '12.4900', if (query['net_type'] == '4') 'app_bytes': _frame(3, 0xAB)}),
        '/webapi/v1/staff/get_bill_detail_by_id' => ok({
          'order_id': query['bill_id'],
          'consume_type': 'bath',
          'status': billStatus,
          'consume_money': billStatus == 'finished' ? 0.14 : liveUsage ? 0.07 : 0.0,
          'charge_money': 5.0,
          'refund_money': billStatus == 'finished' ? 4.86 : 0.0,
          'water_volume_1': billStatus == 'finished' ? 2.34 : liveUsage ? 1.02 : 0.0,
          'consume_timing': 21,
          'pay_channel': 0,
          'deduct_from_coupon': billStatus == 'finished' ? 0.14 : 0.0,
        }),
        '/webapi/v1/consume/remote_end_order' => () {
          billStatus = 'finished';
          return ok({'status': 'finished'});
        }(),
        '/webapi/v1/device/ble/create_hand_shake_cmd' => ok(_frame(1)),
        '/webapi/v1/device/ble/heart_shark_response' => ok({'isn': 'ISN1', 'ratecmd': _frame(16), 'result': occupied ? 3 : 1}),
        '/webapi/v1/device/ble/create_history_order_cmd' => ok(_frame(2)),
        '/webapi/v1/consume/ble/start_consume_response' => ok(null),
        '/webapi/v1/consume/ble/create_end_consume_cmd' => ok(_frame(4)),
        '/webapi/v1/consume/ble/end_consume_response' => () {
          // 历史单（命令 2 的回帧）补传时，在设备上关过水的就此结算；结束帧（命令 4）的回帧是这一单的结算。
          if (query['hex'] == _frame(4, 1) || (historySettles && query['hex'] == _frame(2, 1))) billStatus = 'finished';
          return ok({'status': 'finished'});
        }(),
        _ => fail('not_found'),
      };
    }
    return http.Response(jsonEncode(reply), 200, headers: {'content-type': 'application/json; charset=utf-8'});
  });
}

// 假蓝牙：记下连了哪台（与是不是允许弹权限框）、写了哪些帧；回帧是同一命令类型、第 4 个字节为 1。
class _FakeLink implements ZhuliBleLink {
  final written = <String>[];
  final connects = <String>[];
  final asks = <bool>[];
  var disconnects = 0;
  var _connected = false;
  // 写这一命令类型时设备不回。
  int? silentOn;
  // 连接时就失败（附近找不到、连不上）。
  ZhuliException? connectError;
  // 握手时设备顺带发来一张结束回执（之前在设备上关过水）。
  String? receiptOnHandshake;
  // 连接挂着、等测试放行（看连接期间已经发了哪些请求）。
  Completer<void>? holdConnect;
  final _receipts = StreamController<String>.broadcast();

  @override
  Stream<String> get receipts => _receipts.stream;

  @override
  bool get connected => _connected;

  // 设备自己断开（预先连好后空闲太久）。
  void drop() => _connected = false;

  @override
  Future<void> connect({required String bleName, required String bleMac, bool ask = true}) async {
    asks.add(ask);
    if (connectError case final error?) throw error;
    await holdConnect?.future;
    connects.add(bleName);
    _connected = true;
  }

  @override
  Future<String> exchange(String frame, Set<int> expect) async {
    written.add(frame);
    final command = zhuliFrameCommand(frame)!;
    if (command == silentOn) throw const ZhuliException(ZhuliFailure.rejected, '设备没有回应，靠近一点再试');
    if (command == 1 && receiptOnHandshake != null) _receipts.add(receiptOnHandshake!);
    return _frame(command, 1);
  }

  @override
  Future<void> disconnect() async {
    disconnects++;
    _connected = false;
  }
}

ZhuliService _service(_FakeBath fake) => ZhuliService(vault: MemoryZhuliVault(), devices: ZhuliDeviceStore.memory(), client: ZhuliClient(http: ZhuliHttp(client: fake.client)));

Future<ZhuliService> _signedIn(_FakeBath fake) async {
  final service = _service(fake);
  await service.signIn(_phone, _password);
  return service;
}

// 北京时间 2026-11-22 的某个钟点。
DateTime _beijing(int hour, int minute) => DateTime.utc(2026, 11, 22, hour, minute).subtract(const Duration(hours: 8));

Future<void> _settle(WidgetTester tester, {int rounds = 20}) async {
  for (var index = 0; index < rounds; index++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

bool _dotted(Widget widget, String text) => widget is DotSeparatedText && widget.text == text;

void main() {
  group('扫码、设备与供水时段', () {
    test('设备码同原 App：住理域名链接的 d 或 mac、「十六进制-设备号」、纯 12 位十六进制；别的码不认', () {
      expect(zhuliParseCode('https://zhuli.whxinna.com/?d=1234567'), (deviceId: 1234567, mac: null));
      expect(zhuliParseCode('https://alipay-zhuli.whxinna.com/#/?mac=0A1B2C3D4E5F'), (deviceId: null, mac: '0A:1B:2C:3D:4E:5F'));
      // 设备屏幕上的码（11-26 用户真机扫了说不是设备码）：# 后面整段就是设备号；查询串里有 d 时以它为准（原 App 的 Zi）。
      expect(zhuliParseCode('https://zhuli.whxinna.com/#1234567'), (deviceId: 1234567, mac: null));
      expect(zhuliParseCode('https://zhuli.whxinna.com/#7654321?d=1234567'), (deviceId: 1234567, mac: null));
      expect(zhuliParseCode('0a1b2c3d4e5f-1234567'), (deviceId: 1234567, mac: '0A:1B:2C:3D:4E:5F'));
      expect(zhuliParseCode(' 0A-1B-2C-3D-4E-5F '), (deviceId: null, mac: '0A:1B:2C:3D:4E:5F'));
      expect(zhuliParseCode('https://example.com/?d=1'), isNull, reason: '别的域名不认');
      expect(zhuliParseCode('https://zhuli.whxinna.com/?t=c&i=12345678'), isNull, reason: '卡号不是设备');
      expect(zhuliParseCode('{"cid":"12345678"}'), isNull);
      expect([zhuliMac('0A1B2C3D4E5F'), zhuliMac('0A:1B:2C:3D:4E'), zhuliMac('zz1B2C3D4E5F')], ['0A:1B:2C:3D:4E:5F', null, null]);
    });

    test('开水走哪一路照原 App 的 oi()：change_network 先于优先通道；不止一个通道时看学校设定（3 蓝牙优先、2 走 7）；两用设备能选、写成云端/蓝牙', () {
      ZhuliDevice decode(Map<String, Object?> json) => decodeZhuliDevice(json);
      expect(decode(_device(1, module: '4')).channel, 4);
      expect(decode(_device(1)).channel, 6);
      expect(decode({..._device(1, module: '4'), 'primary_consume_net_type': 6}).channel, 6);
      expect(decode(_device(1, change: '4')).bluetooth, isTrue);
      expect(decode({..._device(1, change: '4'), 'primary_consume_net_type': 6}).channel, 4, reason: 'change_network 先于优先通道');
      final dual = decode(_device(1));
      expect([dual.channelWith(0), dual.channelWith(3), dual.cloudChannel(3), dual.using(4).bluetooth], [6, 4, 6, true]);
      expect([decode({..._device(1), 'net_module': '7,6'}).channelWith(0), decode({..._device(1), 'net_module': '7,6'}).channelWith(2)], [1, 7]);
      expect([dual.dual, dual.modeLabel, decode(_device(1, module: '4')).modeLabel, decode({..._device(1), 'net_module': '6'}).modeLabel], [true, '云端/蓝牙', '蓝牙', '云端']);
      expect([dual.distinctName, decode({..._device(1), 'device_name': 'A1'}).distinctName], [null, 'A1'], reason: '设备名就是房间号时不重复写');
      expect(decodeZhuliConfig({'network_selection': 3}).networkSelection, 3);
      expect(decode({..._device(1), 'net_module': ''}).modules, [64], reason: '没有 net_module 时用 net_type');
      final device = decode(_device(1, supply: jsonEncode([{'start_time': '2025-03-08T06:00:00', 'end_time': '2025-03-08T08:00:00'}, {'start_time': 'x'}])));
      expect(device.supply, [(start: 360, end: 480)], reason: '认不出的段跳过');
      expect(device.place, '1号楼 2层 201');
      expect(decode({..._device(1), 'water_supply_time': '不是 JSON'}).supply, isEmpty);
    });

    test('供水时段按北京时间的钟点比；没给时段当全天供水', () {
      const supply = [(start: 360, end: 480), (start: 1200, end: 1439)];
      expect([zhuliInSupply(supply, _beijing(6, 30)), zhuliInSupply(supply, _beijing(9, 0)), zhuliInSupply(supply, _beijing(23, 59)), zhuliInSupply(const [], _beijing(3, 0))], [true, false, true, true]);
    });

    test('回复的 data 照原 App 解：先 base64、再试 JSON，不是 JSON 就是字本身（命令帧），不是 base64 原样；帧的命令类型在第 3 个字节', () {
      expect(zhuliDecodeData(zhuliBase64(_frame(1))), _frame(1));
      expect(zhuliDecodeData(zhuliBase64(jsonEncode('x'))), 'x');
      expect(zhuliDecodeData(zhuliBase64(jsonEncode({'isn': 'I'}))), {'isn': 'I'});
      expect(zhuliDecodeData('不是*base64'), '不是*base64');
      expect([zhuliFrameCommand(_frame(64)), zhuliFrameCommand('0000')], [64, null]);
    });
  });

  group('本机设备列表', () {
    final entries = [for (var id = 1; id <= 25; id++) ZhuliDeviceEntry(id: id, name: '$id', place: '1号楼 2层 $id')];

    test('最近使用最多 6 台、新的在前、同一台只留一份；常用设备最多 20 台、可置顶与移出；按手机号分开', () async {
      final store = ZhuliDeviceStore.memory();
      for (final entry in entries.take(7)) {
        await store.used(_phone, entry);
      }
      await store.used(_phone, entries[3]);
      expect((await store.load(_phone)).recent.map((entry) => entry.id), [4, 7, 6, 5, 3, 2]);
      for (final entry in entries.take(20)) {
        await store.favor(_phone, entry);
      }
      await expectLater(store.favor(_phone, entries[20]), throwsStateError);
      await store.favor(_phone, entries[0]);
      await store.pin(_phone, 9);
      await store.unfavor(_phone, 2);
      final favorites = (await store.load(_phone)).favorites.map((entry) => entry.id).toList();
      expect(favorites.length, 19);
      expect(favorites.take(3), [9, 1, 3]);
      expect((await store.load('13800000002')).recent, isEmpty);
      await store.deleteAll();
      expect((await store.load(_phone)).favorites, isEmpty);
    });

    test('记下有哪几路与两用设备选的通道：再打开不丢选的通道，常用设备原位跟着更新；说明行写设备号与有哪几路', () async {
      final store = ZhuliDeviceStore.memory();
      final dual = decodeZhuliDevice(_device(101));
      await store.used(_phone, ZhuliDeviceEntry.of(dual));
      await store.favor(_phone, ZhuliDeviceEntry.of(dual));
      await store.prefer(_phone, 101, 4);
      await store.used(_phone, ZhuliDeviceEntry.of(dual));
      final lists = await store.load(_phone);
      expect([lists.recent.single.channel, lists.favorites.single.channel], [4, 4]);
      expect(lists.recent.single.detail, '设备号 101 · 云端/蓝牙');
      expect(const ZhuliDeviceEntry(id: 7, name: '201', place: '1号楼 2层 201').detail, '设备号 7', reason: '11-23 以前记的条目没有模式，名字同房间号不写');
    });

    test('文件是外部输入：坏了当没有；写到临时文件再改名', () async {
      final directory = await Directory.systemTemp.createTemp('zhuli_devices');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/zhuli_devices.json');
      await file.writeAsString('{坏了');
      final store = ZhuliDeviceStore.file(file);
      expect((await store.load(_phone)).recent, isEmpty);
      await store.used(_phone, entries[0]);
      expect(jsonDecode(await file.readAsString()), {_phone: {'recent': [{'id': 1, 'name': '1', 'place': '1号楼 2层 1'}], 'favorites': <Object>[]}});
      expect(File('${file.path}.tmp').existsSync(), isFalse);
      await file.writeAsString(jsonEncode({_phone: {'recent': [{'id': 'x'}, {'id': 2, 'name': '2', 'place': ''}]}}));
      expect((await store.load(_phone)).recent.map((entry) => entry.id), [2], reason: '不合格的条目跳过');
      await store.deleteAll();
      expect(file.existsSync(), isFalse);
    });
  });

  group('开水前检查', () {
    late _FakeBath fake;
    late ZhuliBath bath;

    setUp(() async {
      fake = _FakeBath();
      bath = ZhuliBath(service: await _signedIn(fake), phone: _phone, clock: () => _beijing(21, 0));
    });

    test('都没问题：带回设备、余额、券余额与按分组对上的计费规则', () async {
      final plan = await bath.prepare(101);
      expect((plan.blocked, plan.confirm, plan.running, plan.profile.balance, plan.coupons.balance, plan.rule?.prepaid, plan.rule?.price), (null, null, null, 1749, 17635, 500, 7));
    });

    test('拦下的情形照原 App 的顺序：维护、被使用、没有计费规则、待支付、余额门槛、供水时段', () async {
      Future<String?> blocked(Map<String, Object?> device, {Map<String, Object?>? config, List<Object>? pending}) async {
        fake.devices[101] = device;
        if (config != null) fake.config = {...fake.config, ...config};
        if (pending != null) fake.pending = pending;
        return (await bath.prepare(101)).blocked;
      }

      expect(await blocked(_device(101, status: 6)), '设备正在维护，换一台试试');
      expect(await blocked(_device(101, consume: 0)), '设备正在被使用，换一台试试');
      expect(await blocked(_device(101, group: 1001)), '这台设备没设定计费规则，请联系管理员');
      expect(await blocked({..._device(101), 'device_type': 3}), '这台不是洗浴设备，暂不支持');
      expect(await blocked(_device(101), pending: [{'order_id': 'P1'}]), '你有 1 笔待支付的订单，先在住理生活 App 里付清');
      fake.pending = [];
      expect(await blocked(_device(101), config: {'minimum_consume_balance': 20.0}), '余额不足 ¥20.00，先充值');
      fake.config['continue_use_on_min_consume_balance_enabled'] = 1;
      expect((await bath.prepare(101)).confirm, '余额可能不够这次用水，仍要开吗？');
      fake.config['minimum_consume_balance'] = 0.0;
      final morning = jsonEncode([{'start_time': '2025-03-08T06:00:00', 'end_time': '2025-03-08T08:00:00'}]);
      fake.devices[101] = _device(101, supply: morning);
      expect((await bath.prepare(101)).confirm, '现在不在供水时段，可能没有热水，仍要开吗？');
      expect(await blocked(_device(101, supply: morning), config: {'force_supply_time': 1}), '现在不在供水时段');
      expect(await blocked(_device(101), config: {'bath_enable': 0}), '这个学校没开洗浴');
    });

    test('自己在这台上有没结束的单就接回去；在别的设备上有就先去结束那一单', () async {
      fake.last = {'order_id': 'O9', 'status': 'consuming', 'device_id': 101, 'device_type': 0, 'create_at': '2026-11-22 20:55:00'};
      final plan = await bath.prepare(101);
      expect((plan.running?.orderId, plan.blocked), ('O9', null));
      expect((await bath.prepare(102)).blocked, '你还有一单在用水，先在首页结束那一单');
      expect(await bath.service.run(_phone, bath.service.client.lastRecord), isA<ZhuliLastRecord>());
    });
  });

  group('开水与关水', () {
    late _FakeBath fake;
    late _FakeLink link;
    late ZhuliBath bath;

    setUp(() async {
      fake = _FakeBath();
      link = _FakeLink();
      bath = ZhuliBath(service: await _signedIn(fake), phone: _phone, link: () => link);
    });

    Future<ZhuliDevice> device(int id) => bath.service.run(_phone, (session) => bath.service.client.device(session, id));

    test('云端：先唤醒再下单（net_type 6、端口 0、staff_id 是自己、不发金额）；关水按单号与设备号结算，等到 finished', () async {
      final order = await bath.start(await device(101));
      expect((order.orderId, order.balance), ('O1', 1249));
      expect(fake.count('/webapi/v1/device/collect_gprs_device_status'), 1);
      final query = fake.lastQuery('/webapi/v1/consume/create_order');
      expect((query['net_type'], query['port_name'], query['staff_id'], query['send_to_device'], query['act'], query.containsKey('money')), ('6', '0', 'U1', '1', 'consume', false));
      expect(link.connects, isEmpty);
      final bill = await bath.end(await device(101), 'O1');
      expect(fake.lastQuery('/webapi/v1/consume/remote_end_order'), containsPair('order_id', 'O1'));
      expect((bill.status, bill.money, bill.refund, bill.fromCoupon), ('finished', 14, 486, 14));
    });

    test('蓝牙开水按原 App 搬运帧：握手 → 设费率 → 补传历史单 → 带 isn 下单 → 写开始帧 → 回帧交服务端；做完断开', () async {
      final order = await bath.start(await device(102));
      expect(order.orderId, 'O1');
      expect(link.connects, ['XN-102']);
      expect(link.written, [_frame(1), _frame(16), _frame(2), _frame(3, 0xAB)]);
      expect(fake.lastQuery('/webapi/v1/device/ble/heart_shark_response')['hex'], _frame(1, 1));
      expect(fake.lastQuery('/webapi/v1/device/ble/create_history_order_cmd')['isn'], 'ISN1');
      final create = fake.lastQuery('/webapi/v1/consume/create_order');
      expect((create['isn'], create['net_type'], create['staff_id'], create.containsKey('send_to_device')), ('ISN1', '4', 'U1', false));
      expect(fake.lastQuery('/webapi/v1/consume/ble/start_consume_response'), allOf(containsPair('hex', _frame(3, 1)), containsPair('order_id', 'O1')));
      expect(fake.count('/webapi/v1/device/collect_gprs_device_status'), 0, reason: '蓝牙不唤醒');
      expect(link.disconnects, 1);
    });

    test('补传历史单交给住理之后才下单（同原 App；11-23 真机一起发时补传被回 device_busy）', () async {
      await bath.start(await device(102));
      int at(String path) => fake.requests.indexWhere((uri) => uri.path == path);
      expect(at('/webapi/v1/consume/ble/end_consume_response'), lessThan(at('/webapi/v1/consume/create_order')));
    });

    test('握手帧只要设备号，和连接同时去取：连接还挂着时请求已经发出去', () async {
      final hold = Completer<void>();
      link.holdConnect = hold;
      final target = await device(102);
      final starting = bath.start(target);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(link.connects, isEmpty);
      expect(fake.count('/webapi/v1/device/ble/create_hand_shake_cmd'), 1);
      hold.complete();
      await starting;
      expect(fake.count('/webapi/v1/device/ble/create_hand_shake_cmd'), 1, reason: '不再取第二次');
    });

    test('蓝牙握手说设备被占用：是自己这台上的单就接回去，别人的就换一台；都断开', () async {
      fake
        ..occupied = true
        ..last = {'order_id': 'O9', 'status': 'consuming', 'device_id': 102, 'device_type': 0, 'create_at': '2026-11-22 20:55:00'};
      expect((await bath.start(await device(102))).orderId, 'O9');
      expect(fake.count('/webapi/v1/consume/create_order'), 0);
      expect(link.written, [_frame(1), _frame(16)], reason: '被占用时不补传历史单');
      fake.last = {...fake.last!, 'device_id': 101};
      await expectLater(bath.start(await device(102)), throwsA(isA<ZhuliException>().having((error) => error.message, 'message', '设备正在被使用，换一台试试')));
      expect(link.disconnects, 2);
    });

    test('开始帧设备没回：写明水没开、结果在订单里看，照样断开', () async {
      link.silentOn = 3;
      await expectLater(bath.start(await device(102)), throwsA(isA<ZhuliException>().having((error) => error.message, 'message', contains('水没开'))));
      expect(fake.count('/webapi/v1/consume/ble/start_consume_response'), 0);
      expect(link.disconnects, 1);
    });

    test('蓝牙关水：重连握手（设备被自己占着）→ 写结束帧 → 回帧交服务端结算；在设备上关过水的握手补传后就不再写结束帧', () async {
      fake
        ..occupied = true
        ..billStatus = 'consuming';
      final bill = await bath.end(await device(102), 'O1');
      expect(link.written, [_frame(1), _frame(16), _frame(4)]);
      expect(fake.lastQuery('/webapi/v1/consume/ble/create_end_consume_cmd'), allOf(containsPair('isn', 'ISN1'), containsPair('device_id', '102')));
      expect(fake.lastQuery('/webapi/v1/consume/ble/end_consume_response')['hex'], _frame(4, 1));
      expect(bill.status, 'finished');
      fake
        ..occupied = false
        ..historySettles = true
        ..billStatus = 'consuming';
      link.written.clear();
      expect((await bath.end(await device(102), 'O1')).status, 'finished');
      expect(link.written, [_frame(1), _frame(16), _frame(2)], reason: '历史单补传后已结算，不写结束帧');
    });

    test('连着时设备发来的结束回执交服务端；洗着澡会话过期：只重登并重放那一步，不再写一次帧', () async {
      fake.expireOn = '/webapi/v1/device/ble/heart_shark_response';
      final logins = fake.counter;
      link.receiptOnHandshake = _frame(6, 1);
      await bath.start(await device(102));
      await Future<void>.delayed(Duration.zero);
      expect(fake.counter, logins + 1);
      expect(link.written.where((frame) => frame == _frame(1)).length, 1);
      expect(fake.count('/webapi/v1/device/ble/heart_shark_response'), 2);
      expect(fake.requests.any((uri) => uri.path == '/webapi/v1/consume/ble/end_consume_response' && uri.queryParameters['hex'] == _frame(6, 1)), isTrue);
    });
  });

  group('页面', () {
    late _FakeBath fake;
    late ZhuliService service;

    setUp(() async {
      fake = _FakeBath();
      service = _service(fake);
    });

    Future<void> signIn(WidgetTester tester) async {
      await tester.runAsync(() => service.signIn(_phone, _password));
    }

    testWidgets('云端设备：查完给人看设备、余额与券余额、预扣与单价；开水后等设备开、水开了计时；关水后原地显示这一单的账；开水、关水与完成都不是提示条锚点', (tester) async {
      await signIn(tester);
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ZhuliBathPage(service: service, phone: _phone, deviceId: 101, clock: () => _beijing(21, 0))));
      await _settle(tester);
      expect(find.byType(CampusToastAnchor), findsNothing, reason: '按钮跟着内容滚动，包了提示条会停到页面中间');
      expect(find.text('1号楼 2层 201'), findsOneWidget);
      expect(find.byWidgetPredicate((widget) => _dotted(widget, '设备号 101 · 空闲')), findsOneWidget);
      expect(tester.widget<CampusSegmented<int>>(find.byType(CampusSegmented<int>)).selected, 6, reason: '两用设备默认照原 App 走云端');
      expect(find.text('¥17.49'), findsOneWidget);
      expect(find.text('¥176.35'), findsOneWidget);
      expect(find.byWidgetPredicate((widget) => _dotted(widget, '开水先预扣 ¥5.00 · 关水后按用量多退少补 · ¥0.07/升')), findsOneWidget);
      expect((await tester.runAsync(() => service.devices.load(_phone)))!.recent.single.id, 101, reason: '打开即记进最近使用');
      await tester.tap(find.bySemanticsLabel('收藏到常用设备'));
      await _settle(tester);
      expect(tester.getTopLeft(find.text('已收藏到常用设备')).dy, greaterThan(tester.getBottomLeft(find.text('开水')).dy), reason: '提示条停在页面底部，不停到开水按钮上方压住余额卡');
      hideCampusToast();
      await _settle(tester);
      await tester.tap(find.text('开水'));
      await _settle(tester);
      expect(find.text('等设备开水'), findsOneWidget);
      expect(find.text('¥12.49'), findsOneWidget, reason: '预扣后的余额');
      fake.billStatus = 'consuming';
      fake.liveUsage = false;
      await tester.pump(const Duration(seconds: 3));
      await _settle(tester);
      expect(find.text('用量在关水时结算'), findsOneWidget, reason: '住理开着水时不更新用量，不写 0 升');
      fake.liveUsage = true;
      fake.billStatus = 'consuming';
      await tester.pump(const Duration(seconds: 3));
      await _settle(tester);
      expect(find.text('水已开'), findsOneWidget);
      expect(findDotted('1.02 升 · ¥0.07'), findsOneWidget);
      expect(find.byType(CampusToastAnchor), findsNothing);
      await tester.tap(find.text('关水'));
      await _settle(tester);
      await tester.tap(find.text('关水').last);
      await _settle(tester, rounds: 30);
      expect(find.text('已关水'), findsOneWidget);
      expect(find.text('¥0.14'), findsOneWidget);
      expect(find.text('券 ¥0.14'), findsOneWidget);
      expect(find.byType(CampusToastAnchor), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('蓝牙设备找不到：列出同房间的其他设备（按名字一级级找到房间），一键换过去（人工决策见 zhuliCloudFirst）', (tester) async {
      await signIn(tester);
      final link = _FakeLink()..connectError = const ZhuliException(ZhuliFailure.unreachable, '附近没找到这台设备，靠近一点再试');
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ZhuliBathPage(service: service, phone: _phone, deviceId: 102, link: () => link, clock: () => _beijing(21, 0))));
      await _settle(tester);
      expect(find.byWidgetPredicate((widget) => _dotted(widget, '设备号 102 · 空闲 · 蓝牙')), findsOneWidget);
      expect(find.byType(CampusSegmented<int>), findsNothing, reason: '只有蓝牙的设备没得选');
      await tester.tap(find.text('开水'));
      await _settle(tester);
      expect(find.text('附近没找到这台设备，靠近一点再试'), findsOneWidget);
      expect(findDotted('换到设备号 101 · 云端/蓝牙'), findsOneWidget, reason: '同房间只剩 101，自己不列；同名设备靠设备号分清');
      await tester.tap(findDotted('换到设备号 101 · 云端/蓝牙'));
      await _settle(tester);
      expect(find.byWidgetPredicate((widget) => _dotted(widget, '设备号 101 · 空闲')), findsOneWidget);
      expect(findDotted('换到设备号 101 · 云端/蓝牙'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('两用设备选蓝牙：开水走蓝牙搬帧、关水也走蓝牙；选的记下来，再打开默认蓝牙；学校设定蓝牙优先时默认就是蓝牙', (tester) async {
      await signIn(tester);
      final link = _FakeLink();
      Widget page() => MaterialApp(theme: campusTheme(), home: ZhuliBathPage(key: UniqueKey(), service: service, phone: _phone, deviceId: 101, link: () => link, clock: () => _beijing(21, 0)));
      await tester.pumpWidget(page());
      await _settle(tester);
      await tester.tap(find.text('蓝牙'));
      await _settle(tester);
      expect(find.text('手机靠近设备、打开蓝牙'), findsOneWidget);
      await tester.tap(find.text('开水'));
      await _settle(tester);
      expect(link.connects, ['XN-101'], reason: '页面打开时预先连上，点开水不再连第二次');
      expect(link.asks, [false], reason: '预先连不弹权限框');
      expect(fake.count('/webapi/v1/device/collect_gprs_device_status'), 0, reason: '没走云端');
      expect(fake.lastQuery('/webapi/v1/consume/create_order')['net_type'], '4');
      expect((await tester.runAsync(() => service.devices.load(_phone)))!.recent.single.channel, 4);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(page());
      await _settle(tester);
      expect(tester.widget<CampusSegmented<int>>(find.byType(CampusSegmented<int>)).selected, 4, reason: '上次选的蓝牙');
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => service.devices.deleteAll());
      fake.config = {...fake.config, 'network_selection': 3};
      await tester.pumpWidget(page());
      await _settle(tester);
      expect(tester.widget<CampusSegmented<int>>(find.byType(CampusSegmented<int>)).selected, 4, reason: '学校设定蓝牙优先');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('预先连：只有蓝牙的设备打开页面就连上，点开水直接用；预先连的已经断了就当场再连；关水弹确认时就连，取消就断开', (tester) async {
      await signIn(tester);
      final link = _FakeLink();
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ZhuliBathPage(service: service, phone: _phone, deviceId: 102, link: () => link, clock: () => _beijing(21, 0))));
      await _settle(tester);
      expect(link.connects, ['XN-102'], reason: '打开页面就在后台连');
      link.drop();
      await tester.tap(find.text('开水'));
      await _settle(tester);
      expect(link.connects, ['XN-102', 'XN-102'], reason: '预先连的断了，当场再连');
      expect(link.asks.last, isTrue, reason: '用户点了开水才可以问权限');
      expect(find.text('关水'), findsOneWidget);
      final before = link.disconnects;
      await tester.tap(find.text('关水'));
      await _settle(tester);
      expect(link.connects.length, 3, reason: '弹确认时就开始连');
      await tester.tap(find.text('取消'));
      await _settle(tester);
      expect(link.disconnects, greaterThan(before), reason: '取消就断开');
      expect(find.text('关水'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('拦下时写原因、不给开水；星标收藏到常用设备', (tester) async {
      await signIn(tester);
      fake.devices[101] = _device(101, status: 6);
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ZhuliBathPage(service: service, phone: _phone, deviceId: 101)));
      await _settle(tester);
      expect(find.text('设备正在维护，换一台试试'), findsOneWidget);
      expect(find.text('开水'), findsNothing);
      await tester.tap(find.bySemanticsLabel('收藏到常用设备'));
      await _settle(tester);
      expect((await tester.runAsync(() => service.devices.load(_phone)))!.favorites.single.id, 101);
      expect(find.bySemanticsLabel('移出常用设备'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('首页：洗浴卡的三个入口、最近使用与常用设备；有没结束的单时最上面一条「正在用水」', (tester) async {
      final fixture = ToolboxFixture();
      await tester.runAsync(fixture.initialize);
      addTearDown(fixture.close);
      await tester.runAsync(() async {
        await fixture.store.grantConsent(ZhuliService.serviceId, ZhuliService.consentVersion);
        await service.signIn(_phone, _password);
        for (final id in [103, 101, 102]) {
          await service.devices.used(_phone, ZhuliDeviceEntry(id: id, name: '', place: '1号楼 2层 201', mode: id == 101 ? '云端/蓝牙' : '蓝牙'));
        }
      });
      fake.last = {'order_id': 'O9', 'status': 'consuming', 'device_id': 102, 'device_type': 0, 'create_at': '2026-11-22 20:55:00'};
      final blueFirst = {102: fake.devices[102]!, 101: fake.devices[101]!};
      fake.devices
        ..clear()
        ..addAll(blueFirst);
      final runtime = ToolboxRuntime.testing(catalog: toolboxCatalog, store: fixture.store, downloads: fixture.manager, services: {ZhuliService.serviceId: service});
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ZhuliPage(runtime: runtime)));
      await _settle(tester);
      expect(find.text('正在用水'), findsOneWidget);
      expect(find.byWidgetPredicate((widget) => widget is DotSeparatedText && widget.text.startsWith('设备号 102 · ') && widget.text.endsWith('开始')), findsOneWidget, reason: '正在用水写设备号');
      expect(find.text('设备号'), findsOneWidget);
      expect(find.text('按楼栋选'), findsOneWidget);
      expect(find.text('扫码'), findsNothing, reason: '测试里没有扫码能力');
      expect(tester.getTopLeft(find.text('常用设备')).dy, lessThan(tester.getTopLeft(find.text('设备号')).dy), reason: '常用设备与按楼栋选在前');
      expect(tester.getTopLeft(find.text('洗浴')).dy, lessThan(tester.getTopLeft(find.text('余额')).dy), reason: '洗浴在余额前面');
      // 最近使用默认两台，点「全部」展开。
      expect(find.byWidgetPredicate((widget) => _dotted(widget, '设备号 102 · 蓝牙')), findsOneWidget);
      expect(find.byWidgetPredicate((widget) => _dotted(widget, '设备号 101 · 云端/蓝牙')), findsOneWidget);
      expect(find.byWidgetPredicate((widget) => _dotted(widget, '设备号 103 · 蓝牙')), findsNothing);
      await tester.tap(find.text('全部 3 台'));
      await _settle(tester);
      expect(find.byWidgetPredicate((widget) => _dotted(widget, '设备号 103 · 蓝牙')), findsOneWidget);
      expect(find.text('收起'), findsOneWidget);
      // 按楼栋选：只列有设备的房间，选中设备进洗浴页。
      await tester.tap(find.text('按楼栋选'));
      await _settle(tester);
      expect(find.text('280 台'), findsOneWidget, reason: '楼栋的台数是 total_count');
      await tester.tap(find.text('1号楼'));
      await _settle(tester);
      await tester.tap(find.text('2层'));
      await _settle(tester);
      expect(find.text('200'), findsNothing);
      await tester.tap(find.text('201'));
      await _settle(tester);
      expect(find.byWidgetPredicate((widget) => _dotted(widget, '空闲 · 蓝牙')), findsOneWidget);
      expect(find.byWidgetPredicate((widget) => _dotted(widget, '空闲 · 云端/蓝牙')), findsOneWidget);
      expect(tester.getTopLeft(find.text('设备号 101')).dy, lessThan(tester.getTopLeft(find.text('设备号 102')).dy), reason: '能走云端的排前面，住理回的顺序是蓝牙在前');
      expect(find.byType(ZhuliPickPage, skipOffstage: false), findsNWidgets(4), reason: '每一级推一个页面（同全应用的转场与跟手返回）');
      await tester.tap(find.text('设备号 101'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(ZhuliPickPage, skipOffstage: false), findsOneWidget, reason: '下面几级当场拿掉，只剩最上面这一页随洗浴页推入退场（11-23 视频里几页一起闪）');
      expect(find.byType(ZhuliPage, skipOffstage: false), findsOneWidget);
      await _settle(tester);
      expect(find.byType(ZhuliPickPage, skipOffstage: false), findsNothing, reason: '选择页换成了洗浴页');
      expect(find.byType(ZhuliBathPage), findsOneWidget);
      final loads = fake.count('/webapi/v1/staff/get_user_detail_by_id');
      await tester.tap(find.byTooltip('返回'));
      await _settle(tester);
      expect(find.byType(ZhuliBathPage), findsNothing);
      expect(find.byType(ZhuliPickPage, skipOffstage: false), findsNothing, reason: '返回直接回首页');
      expect(fake.count('/webapi/v1/staff/get_user_detail_by_id'), greaterThan(loads), reason: '洗浴页关掉后首页刷新');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('扫码洗浴：扫码页直接换成洗浴页（不先回首页再推）；扫到蓝牙地址的码在洗浴页里换成设备号', (tester) async {
      final fixture = ToolboxFixture();
      await tester.runAsync(fixture.initialize);
      addTearDown(fixture.close);
      await tester.runAsync(() async {
        await fixture.store.grantConsent(ZhuliService.serviceId, ZhuliService.consentVersion);
        await service.signIn(_phone, _password);
      });
      String? rejected;
      final runtime = ToolboxRuntime.testing(
        catalog: toolboxCatalog,
        store: fixture.store,
        downloads: fixture.manager,
        services: {ZhuliService.serviceId: service},
        scanQrCode: (context, hint, accept, {then}) async {
          rejected = accept('https://example.com');
          expect(accept('40BD32000065'), isNull);
          unawaited(Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => then!('40BD32000065'))));
          return null;
        },
      );
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ZhuliPage(runtime: runtime)));
      await _settle(tester);
      await tester.tap(find.text('扫码'));
      await _settle(tester);
      expect(rejected, '不是住理生活的设备码');
      expect(find.byType(ZhuliBathPage), findsOneWidget);
      expect(fake.lastQuery('/webapi/v1/device/get_by_mac')['mac'], '40:BD:32:00:00:65');
      expect(find.byWidgetPredicate((widget) => _dotted(widget, '设备号 101 · 空闲')), findsOneWidget, reason: '地址换成了设备号');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('常用设备按楼栋选添加：选中后几级一起收掉、一次退回常用设备页', (tester) async {
      final fixture = ToolboxFixture();
      await tester.runAsync(fixture.initialize);
      addTearDown(fixture.close);
      await signIn(tester);
      final runtime = ToolboxRuntime.testing(catalog: toolboxCatalog, store: fixture.store, downloads: fixture.manager, services: {ZhuliService.serviceId: service});
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ZhuliFavoritesPage(runtime: runtime, service: service, phone: _phone)));
      await _settle(tester);
      await tester.tap(find.bySemanticsLabel('添加常用设备'));
      await _settle(tester);
      await tester.tap(find.text('按楼栋选'));
      await _settle(tester);
      for (final level in ['1号楼', '2层', '201']) {
        await tester.tap(find.text(level));
        await _settle(tester);
      }
      await tester.tap(find.text('设备号 101'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(ZhuliPickPage, skipOffstage: false), findsOneWidget, reason: '下面几级当场拿掉，只有最上面这一页退场');
      await _settle(tester);
      expect(find.byType(ZhuliPickPage, skipOffstage: false), findsNothing);
      expect(find.byType(ZhuliFavoritesPage), findsOneWidget);
      expect((await tester.runAsync(() => service.devices.load(_phone)))!.favorites.single.id, 101);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('常用设备：输设备号添加（先向住理查名字与位置），⋯ 里置顶与移出', (tester) async {
      final fixture = ToolboxFixture();
      await tester.runAsync(fixture.initialize);
      addTearDown(fixture.close);
      await signIn(tester);
      final runtime = ToolboxRuntime.testing(catalog: toolboxCatalog, store: fixture.store, downloads: fixture.manager, services: {ZhuliService.serviceId: service});
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ZhuliFavoritesPage(runtime: runtime, service: service, phone: _phone)));
      await _settle(tester);
      expect(find.text('还没有常用设备'), findsOneWidget);
      for (final id in ['101', '102']) {
        await tester.tap(find.bySemanticsLabel('添加常用设备'));
        await _settle(tester);
        await tester.tap(find.text('输设备号'));
        await _settle(tester);
        await tester.enterText(find.byType(TextField), id);
        await tester.pump();
        await tester.tap(find.text('打开'));
        await _settle(tester);
      }
      expect(find.byWidgetPredicate((widget) => _dotted(widget, '设备号 101 · 云端/蓝牙')), findsOneWidget);
      expect(find.byWidgetPredicate((widget) => _dotted(widget, '设备号 102 · 蓝牙')), findsOneWidget);
      await tester.tap(find.byTooltip('更多').last);
      await _settle(tester);
      await tester.tap(find.text('置顶'));
      await _settle(tester);
      expect((await tester.runAsync(() => service.devices.load(_phone)))!.favorites.map((entry) => entry.id), [102, 101]);
      await tester.tap(find.byTooltip('更多').first);
      await _settle(tester);
      await tester.tap(find.text('移出常用设备'));
      await _settle(tester);
      expect((await tester.runAsync(() => service.devices.load(_phone)))!.favorites.map((entry) => entry.id), [101]);
      await tester.pumpWidget(const SizedBox());
    });
  });

  // 安卓调高连接优先级经反射读蓝牙插件的私有字段（[人工决策] 在 ZhuliBleBoost.kt）：插件升级改了名字、混淆规则或通道丢了，这里先报出来。
  test('蓝牙插件里调连接优先级要用的两个私有字段还在，release 包保留它们的名字，通道登记了', () {
    final config = jsonDecode(File('.dart_tool/package_config.json').readAsStringSync()) as Map<String, Object?>;
    final plugin = (config['packages']! as List).cast<Map<String, Object?>>().singleWhere((package) => package['name'] == 'bluetooth_low_energy_android');
    final root = Uri.parse(plugin['rootUri']! as String).isAbsolute
        ? Directory.fromUri(Uri.parse(plugin['rootUri']! as String))
        : Directory.fromUri(File('.dart_tool/package_config.json').absolute.uri.resolve(plugin['rootUri']! as String));
    final source = '${root.path}/android/src/main/kotlin/dev/zeekr/bluetooth_low_energy_android';
    expect(File('$source/BluetoothLowEnergyAndroidPlugin.kt').readAsStringSync(), contains('private var mCentralManager: CentralManagerImpl?'));
    expect(File('$source/CentralManagerImpl.kt').readAsStringSync(), contains('private val mGATTs: MutableMap<String, BluetoothGatt>'));
    final rules = File('android/app/proguard-rules.pro').readAsStringSync();
    expect(rules, contains('-keepclassmembers class dev.zeekr.bluetooth_low_energy_android.BluetoothLowEnergyAndroidPlugin { private ** mCentralManager; }'));
    expect(rules, contains('-keepclassmembers class dev.zeekr.bluetooth_low_energy_android.CentralManagerImpl { private ** mGATTs; }'));
    expect(File('android/app/src/main/kotlin/com/superxd/superxd/MainActivity.kt').readAsStringSync(), contains('"superxd/zhuli_ble"'));
  });

  test('注册表：住理生活登记了「扫码洗浴」快捷入口（id 发出后不改），清除数据写明含设备列表', () async {
    final fixture = ToolboxFixture();
    await fixture.initialize();
    addTearDown(fixture.close);
    final zhuli = toolboxTree(toolboxCatalog(fixture.runtime)).firstWhere((module) => module.id == ZhuliService.serviceId);
    expect(zhuli.shortcuts.map((shortcut) => (shortcut.id, shortcut.label)), [('scan', '扫码洗浴')]);
    expect(zhuli.clearedData, contains('常用设备'));
  });
}
