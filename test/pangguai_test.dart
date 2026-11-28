import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:superxd/domain/feature_flags.dart';
import 'package:superxd/theme/campus_glass_controls.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/dot_separated_text.dart';
import 'package:superxd/toolbox/life/life_alipay.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_captcha.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_client.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_device_page.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_devices.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_http.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_location.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_models.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_order_page.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_page.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_protocol.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_service.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_vault.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_water_page.dart';
import 'package:superxd/toolbox/toolbox_catalog.dart';
import 'package:superxd/toolbox/toolbox_page.dart';
import 'package:superxd/toolbox/toolbox_runtime.dart';

import 'toolbox_test_support.dart';

// 胖乖生活（人工决策见 lib/toolbox/life/pangguai/pangguai_service.dart 文件头）：协议、数据、请求、服务与页面。数据全是合成的，设备号、订单号都是编的。

const _phone = '13800000001', _other = '13800000002', _code = '2468';
const _washer = '9001', _dryer = '9002', _offline = '9003', _afterPay = '9004';
const _nqt = '00000000-0000-4000-8000-000000000001';
const _hash = 'ABCDEF0123456789ABCDEF0123456789';

// 一次请求：路径、请求头与表单（multipart 的也解成键值）。
class _Request {
  _Request(this.host, this.path, this.headers, this.fields);
  final String host;
  final String path;
  final Map<String, String> headers;
  final Map<String, String> fields;
}

Map<String, String> _fields(http.Request request) {
  final type = request.headers['content-type'] ?? '';
  if (type.startsWith('multipart/form-data')) {
    return {for (final match in RegExp(r'name="([^"]+)"\r\n\r\n([^\r]*)\r\n').allMatches(request.body)) match[1]!: match[2]!};
  }
  return request.body.isEmpty ? {} : Uri.splitQueryString(request.body);
}

// 内存里的假胖乖：按路径回合成数据，记下每次请求。
class _FakePangguai {
  final requests = <_Request>[];
  var needsCaptcha = false;
  // 下一次试算多加的钱（造「价变了」）。
  var bump = 0;
  // 这些路径回 405（防火墙）。
  final blocked = <String>{};
  // 这些路径不回（网络断开）。
  final dropped = <String>{};
  // 失效的凭据（回业务码 2）。
  final expired = <String>{};
  var tokenCounter = 0;
  var orderCounter = 0;
  final orders = <String, Map<String, Object?>>{};
  var waterBalance = 4.65;
  var waterState = 0;
  // 新订单的创建时刻（胖乖写北京时间）。
  var createdAt = '2026-11-27 21:40:47';

  static Map<String, Object?> sku(String id, String name, String price, String unit, {List<Map<String, Object?>>? tiers}) => {
    'skuId': int.parse(id),
    'name': name,
    'feature': '$name说明',
    'price': price,
    'discountPrice': price,
    'unit': unit,
    'stockState': 1,
    'scanAvailable': true,
    'extAttr': tiers == null ? '{"pulse": 0, "scanAvailable": "true"}' : jsonEncode({'perPrice': tiers, 'scanAvailable': true}),
  };

  final skus = <String, List<Map<String, Object?>>>{
    _washer: [sku('1101', '标准洗', '4.00', '35'), sku('1102', '桶自洁', '1.00', '2')],
    _dryer: [
      sku('2101', '左边1号', '0.22', '1', tiers: [
        {'price': '1', 'time': '5', 'status': true},
        {'price': '0.66', 'time': '3', 'status': true},
        {'price': '1.2', 'time': '7', 'status': false},
      ]),
      sku('2102', '右边2号', '0.2', '1', tiers: [
        {'price': '0.66', 'time': '3', 'status': true},
      ]),
    ],
  };

  Map<String, Object?> device(String goodsId) => {
    'goodsId': int.parse(goodsId),
    'name': switch (goodsId) { _washer => '合成楼-201', _dryer => '合成楼3层吹风', _ => '合成设备' },
    'categoryCode': goodsId == _dryer ? '03' : goodsId == _afterPay ? '04' : '00',
    'orgId': 100000001,
    'orgName': '合成门店',
    'payment': goodsId == _afterPay ? 'after' : 'before',
    'imei': '860000000000001',
    'shopId': '200000000000000000000000000001',
    'deviceErrorCode': goodsId == _offline ? 4204 : null,
    'deviceErrorMsg': null,
  };

  int price(String items) {
    final item = (jsonDecode(items) as List).single as Map;
    final all = skus[item['goodsId']] ?? const [];
    final chosen = all.firstWhere((each) => '${each['skuId']}' == item['skuId']);
    final tiers = jsonDecode(chosen['extAttr']! as String)['perPrice'] as List?;
    final yuan = tiers == null ? chosen['price']! as String : (tiers.firstWhere((tier) => tier['time'] == item['amount']) as Map)['price'] as String;
    return (double.parse(yuan) * 100).round() + bump;
  }

  late final client = MockClient((request) async {
    final fields = _fields(request);
    requests.add(_Request(request.url.host, request.url.path, request.headers, fields));
    final path = request.url.path;
    if (dropped.contains(path)) throw http.ClientException('dropped');
    if (blocked.contains(path)) return http.Response('<html>blocked</html>', 405);
    if (request.url.host == 'apwork.cn') {
      return _json({'success': fields['token'] == 'W-S' ? 'success' : 'token', 'giftAmountList': [
        {'giftAmountSubId': 64950, 'rechargeAmount': 10, 'giftAmount': 0},
        {'giftAmountSubId': 64953, 'rechargeAmount': 100, 'giftAmount': 10},
      ]});
    }
    Object? data;
    Map<String, Object?> ok(Object? value) => {'code': 0, 'msg': '成功', 'data': value};
    Map<String, Object?> fail(int code, String message) => {'code': code, 'msg': message, 'data': null};
    final token = fields['token'] ?? '';
    if (!const {'/common/isNeedCaptcha', '/captcha/checkCaptcha', '/common/sms/sendCode', '/user/reg'}.contains(path) && (token.isEmpty || expired.contains(token))) {
      return _json(fail(2, '请先登录'));
    }
    switch (path) {
      case '/common/isNeedCaptcha':
        return _json(ok(needsCaptcha));
      case '/captcha/checkCaptcha':
        return _json(fields['validate'] == 'V-OK' ? ok(true) : fail(-1, '安全验证没通过'));
      case '/common/sms/sendCode':
        return _json(ok(true));
      case '/user/reg':
        return _json(fields['verify'] == _code ? ok({'token': 'T${++tokenCounter}', 'forcedBind': false}) : fail(-1, '验证码错误'));
      case '/user/info':
        data = {'id': 'U1', 'userName': '合成用户', 'balance': '0.00'};
      case '/goods/scan/v2':
        data = {'id': int.parse(fields['NQT'] == _nqt ? _washer : _dryer), 'categoryCode': '00'};
      case '/goods/normal/details':
        data = device(fields['goodsId']!);
      case '/goods/normal/skus':
        data = skus[fields['goodsId']] ?? const [];
      case '/trade/preview/v4':
        data = {'realPrice': (price(fields['items']!) / 100).toStringAsFixed(2)};
      case '/trade/create':
        final id = '01202611272140477${(++orderCounter).toString().padLeft(5, '0')}';
        orders[id] = {'id': id, 'orderNo': id, 'orderStatus': 0, 'payPrice': (price(fields['items']!) / 100).toStringAsFixed(2), 'machineName': '合成楼-201', 'machineFunctionName': '桶自洁', 'shopName': '合成门店', 'shopAutoId': 100000001, 'createTime': createdAt, 'payTime': null, 'completeTime': null};
        data = {'tradeType': 1, 'tradeNo': id, 'orderId': id};
      case '/order/detail':
        data = orders[fields['orderId']];
      case '/order/list':
        data = {'total': orders.length, 'items': orders.values.toList().reversed.toList()};
      case '/payChannelRoute/againPay':
        data = [
          {'method': 2, 'useStatus': true},
          {'method': 13, 'useStatus': true},
        ];
      case '/pay/unify/prePay':
        data = {'exist': false, 'prepayParam': 'app_id=1&method=alipay.trade.app.pay&biz_content=x&sign=y'};
      // 同真实胖乖：只有待付款（0）的能取消，取消后是 1（已取消），不是 0 的回 3122；隐藏才从列表拿掉。
      case '/order/cancel':
        final order = orders[fields['orderId']];
        if (order == null || order['orderStatus'] != 0) return _json(fail(3122, '只有未支付订单才能取消'));
        order['orderStatus'] = 1;
        data = null;
      case '/order/hidden':
        orders.remove(fields['orderId']);
        data = null;
      case '/shop/nearby/list':
        data = {'total': 1, 'items': [{'id': '200000000000000000000000000001', 'orgId': 100000001, 'name': '合成门店', 'address': '合成路 1 号', 'distance': 1260, 'machineCount': 20, 'freeMachine': 19}]};
      case '/appointNew/newNearByList':
        data = [{'machineTypeId': '00', 'machineTypeName': '洗衣', 'parentTypeId': 1}];
      case '/appointNew/near/newMachines':
        data = {'goodsPage': 1, 'items': [
          {'goodsId': int.parse(_washer), 'goodsName': '合成楼-201', 'deviceWorkStatus': 10, 'isReserve': 1, 'endUseTimeValue': ''},
          {'goodsId': 9010, 'goodsName': '合成楼-202', 'deviceWorkStatus': 20, 'isReserve': 1, 'endUseTimeValue': '21分钟'},
        ]};
      case '/distributor/scan':
        data = waterScan();
      case '/distributor/unlock':
        data = {'lock': true, 'data': 'WORKING1'};
      case '/distributor/deviceStatus':
        data = {'deviceWorkStatus': waterState};
      case '/distributorOrder/list':
        data = {'total': 1, 'items': [{'orderNo': '0410000000000000000001', 'thirdCreateTime': '2026-11-27 22:03:56', 'status': 1000, 'goodsName': '0000001', 'realPrice': '0.05'}]};
      default:
        return _json(fail(404, '没有这个接口'));
    }
    return _json(ok(data));
  });

  Map<String, Object?> waterScan() => {
          'deviceName': '合成直饮水',
          'respCode': '0000',
          'token': 'W-S',
          'deviceWorkStatus': 1,
          'redirectUrl': 'https://apwork.cn/ewash/water-qie/recharge.html?merchantId=ABCD&washerAreaId=DCBA',
          'accountInfo': {'accountId': 'A1', 'areaId': 6519, 'amount': waterBalance, 'giftAmount': 0.0, 'totalBalance': waterBalance, 'isShare': 1},
          'waterInit': {'maxWater': 5.0, 'balanceLimit': 0.3},
          'deviceInfo': {'macAddress': '0QHJM0000001', 'buildName': '合成公寓', 'floors': '2', 'washerId': 'W1', 'deviceStatus': 0, 'areaName': '合成校区'},
          'accountShare': [{'areaId': 6519, 'totalBalance': waterBalance, 'areaName': '合成校区'}],
          'waterPassageways': [
            {'passagewayName': '开水', 'passagewaySettingId': 4063, 'passgetwaySort': 1, 'status': 1, 'waterCharge': 0.3},
            {'passagewayName': '常温水', 'passagewaySettingId': 1556, 'passgetwaySort': 3, 'status': 1, 'waterCharge': 0.2},
            {'passagewayName': '冰水', 'passagewaySettingId': 1557, 'passgetwaySort': 4, 'status': 0, 'waterCharge': 0.2},
          ],
      };

  // 付款成功：订单变成使用中，带付款时刻与预计结束时刻（北京时间）。
  void pay(String orderId) => orders[orderId]!
    ..['orderStatus'] = 2
    ..['payTime'] = '2026-11-27 21:42:40'
    ..['completeTime'] = '2026-11-27 21:44:40';

  List<String> paths() => [for (final request in requests) request.path];
}

http.Response _json(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});

class _FakeAlipay implements LifeAlipay {
  final paid = <String>[];
  var status = '9000';
  void Function()? onPay;
  @override
  Future<String> pay(String orderContent) async {
    paid.add(orderContent);
    onPay?.call();
    return status;
  }
}

class _FakeLocator implements PangguaiLocator {
  PangguaiLocationProblem? problem;
  final asked = <bool>[];
  final opened = <PangguaiLocationProblem>[];
  @override
  Future<PangguaiPosition> current({required bool ask}) async {
    asked.add(ask);
    if (problem case final problem?) throw PangguaiLocationException(problem);
    return (latitude: 36.123456, longitude: 117.654321);
  }

  @override
  Future<void> openSettings(PangguaiLocationProblem problem) async => opened.add(problem);
}

class _FakeCaptcha implements PangguaiCaptcha {
  String? answer = 'V-OK';
  var shown = 0;
  @override
  Future<String?> verify({required bool dark}) async {
    shown++;
    return answer;
  }
}

class _Kit {
  final fake = _FakePangguai();
  final alipay = _FakeAlipay();
  final locator = _FakeLocator();
  final captcha = _FakeCaptcha();
  final vault = MemoryPangguaiVault();
  late final service = PangguaiService(
    vault: vault,
    devices: PangguaiDeviceStore.memory(),
    client: PangguaiClient(http: PangguaiHttp(client: fake.client, spacing: Duration.zero)),
    alipay: alipay,
    locator: locator,
    captcha: captcha,
  );

  Future<void> signIn([String phone = _phone]) => service.signIn(phone, _code, dark: false);
}

class _Gate implements FeatureGate {
  _Gate(this.on);
  final Set<String> on;
  @override
  bool isOn(FeatureFlag flag) => on.contains(flag.id);
  @override
  Stream<void> get changes => const Stream.empty();
}

void main() {
  group('协议与数据', () {
    test('签名与位置签名照官方 App 的写法（期望值用 Python 按同一串独立算出）', () {
      expect(pangguaiSign('/user/info', token: 'T0KEN', timestamp: '1795785208442'), 'f8868422d79a25dffff8b1851a31b62b3730eb7e44cf4d443a8edbbecc5736b6');
      expect(
        pangguaiRiskSign('/trade/create', token: 'T0KEN', timestamp: '1795785208442', category: '03', imei: '860000000000001', latitude: '36.123456', longitude: '117.654321'),
        '18d11e65b7d934e85f0737c7542c809bddc7f22af0c03b52e8d844ddf544ab40',
      );
    });

    test('认码：胖乖链接的 NQT、IMEI、SN，单独的 NQT 与饮水机码；别的不认', () {
      expect(pangguaiParseCode('https://h5.qiekj.com/skip?NQT=$_nqt'), (key: 'NQT', value: _nqt));
      expect(pangguaiParseCode('https://qiekj.com/x?IMEI=860000000000001'), (key: 'IMEI', value: '860000000000001'));
      expect(pangguaiParseCode(' $_nqt '), (key: 'NQT', value: _nqt));
      expect(pangguaiParseCode('https://apwork.cn/scan/qie?$_hash'), (key: 'water', value: _hash));
      expect(pangguaiParseCode(_hash), (key: 'water', value: _hash));
      for (final other in ['https://example.com/skip?NQT=$_nqt', 'https://h5.qiekj.com/skip?x=1', 'alipays://platformapi/startapp', 'https://apwork.cn/scan/qie?123', '随便一段字']) {
        expect(pangguaiParseCode(other), isNull, reason: other);
      }
    });

    test('档位：洗衣机的程序写约几分钟与标价；吹风机的时长档按分钟排、关着的不能选；items 照契约写', () {
      final fake = _FakePangguai();
      final washer = decodePangguaiSkus(fake.skus[_washer]);
      expect([for (final sku in washer) (sku.id, sku.minutes, sku.price, sku.tiers.length)], [('1101', 35, 400, 0), ('1102', 2, 100, 0)]);
      final dryer = decodePangguaiSkus(fake.skus[_dryer]);
      expect([for (final tier in dryer.first.tiers) (tier.minutes, tier.price, tier.enabled)], [(3, 66, true), (5, 100, true), (7, 120, false)]);
      final washerDevice = decodePangguaiDevice(fake.device(_washer)), dryerDevice = decodePangguaiDevice(fake.device(_dryer));
      expect(jsonDecode(pangguaiItems(washerDevice, washer.last, null)), [{'goodsId': _washer, 'skuId': '1102', 'amount': '1', 'soldType': '1', 'num': '1'}]);
      expect(jsonDecode(pangguaiItems(dryerDevice, dryer.first, 3)), [{'goodsId': _dryer, 'skuId': '2101', 'amount': '3', 'soldType': '1', 'num': '3'}]);
      expect(() => pangguaiItems(dryerDevice, dryer.first, 7), throwsA(isA<PangguaiException>()));
      expect(() => pangguaiItems(dryerDevice, dryer.first, null), throwsA(isA<PangguaiException>()));
    });

    test('设备不能下单的原因：状态码可能是数字、先用后付与别的品类去官方 App', () {
      final fake = _FakePangguai();
      expect(decodePangguaiDevice(fake.device(_washer)).unusable, isNull);
      expect(decodePangguaiDevice(fake.device(_offline)).unusable, contains('4204'));
      expect(decodePangguaiDevice(fake.device(_afterPay)).unusable, contains('先用后付'));
      expect(decodePangguaiDevice({...fake.device(_washer), 'categoryCode': '05'}).unusable, contains('App'));
    });

    test('订单：北京时间换成 UTC；0 待付款，1 已取消（11-28 真机查明，不是待付款），2 使用中，3 已完成；列表没有付款时刻', () {
      final order = decodePangguaiOrder({'id': 'O1', 'orderNo': 'O1', 'orderStatus': 2, 'payPrice': '1.00', 'payTime': '2026-11-27 21:42:40', 'completeTime': '2026-11-27 21:44:40', 'createTime': '2026-11-27 21:40:47', 'shopAutoId': 100000001});
      expect((order.paidAt, order.endsAt, order.running, order.payable, order.price, order.orgId), (DateTime.utc(2026, 11, 27, 13, 42, 40), DateTime.utc(2026, 11, 27, 13, 44, 40), true, false, 100, '100000001'));
      for (final (status, label, payable) in [(0, '待付款', true), (1, '已取消', false), (2, '使用中', false), (3, '已完成', false), (9, '状态 9', false)]) {
        final order = decodePangguaiOrder({'id': 'O1', 'orderNo': 'O1', 'orderStatus': status, 'payPrice': '1.00'});
        expect((order.statusLabel, order.payable, order.cancelled), (label, payable, status == 1));
      }
      expect(() => decodePangguaiOrder({'id': 'O1', 'orderNo': 'O1', 'orderStatus': '待付', 'payPrice': '1.00'}), throwsA(isA<PangguaiException>()));
    });

    test('只认支付宝 APP 支付串；饮水机的两套凭据与充值标识分开；充值链接同官方的两次编码', () {
      expect(decodePangguaiPrepay({'prepayParam': 'method=alipay.trade.app.pay&x=1'}), 'method=alipay.trade.app.pay&x=1');
      expect(() => decodePangguaiPrepay({'prepayParam': 'weixin://pay'}), throwsA(isA<PangguaiException>()));
      final water = decodePangguaiWater(_hash, {
        'respCode': '0000', 'token': 'W-S', 'deviceName': '合成直饮水', 'redirectUrl': 'https://apwork.cn/ewash/water-qie/recharge.html?merchantId=ABCD&washerAreaId=DCBA',
        'accountInfo': {'accountId': 'A1', 'areaId': 6519, 'totalBalance': 5.33, 'isShare': 0},
        'waterInit': {'balanceLimit': 0.3}, 'deviceInfo': {'macAddress': 'M', 'washerId': 'W1', 'deviceStatus': 0, 'buildName': '合成公寓', 'floors': '2', 'areaName': '合成校区'},
        'waterPassageways': [{'passagewayName': '常温水', 'passagewaySettingId': 1556, 'passgetwaySort': 3, 'status': 1, 'waterCharge': 0.2}],
      });
      expect((water.session, water.merchantId, water.merchantAreaId, water.place, water.minimum, water.cards.single.balance, water.cards.single.name), ('W-S', 'ABCD', 'DCBA', '合成公寓 2楼', 30, 533, '合成校区'));
      expect(() => decodePangguaiWater(_hash, {'respCode': '1001'}), throwsA(isA<PangguaiException>()));
      expect(
        pangguaiRechargeUri(session: 'S3SS', merchantId: 'ABCD', merchantAreaId: 'DCBA', tierId: '64950', phone: _phone).toString(),
        'alipays://platformapi/startapp?appId=2021003142624414&page=pages/index/index?token%3DS3SS%26mId%3DABCD%26aId%3DDCBA%26amountSubId%3D64950%26phone%3D13800000001',
      );
    });
  });

  group('请求', () {
    test('凭据在请求头与表单两处都带，签名头按路径算；下单另带设备与位置签名', () async {
      final kit = _Kit();
      await kit.signIn();
      await kit.service.place(_phone, goodsId: _washer, skuId: '1102', expected: 100);
      final info = kit.fake.requests.firstWhere((request) => request.path == '/user/info');
      expect((info.headers['authorization'], info.fields['token'], info.headers['channel'], info.headers['version']), ('T1', 'T1', 'android_app', '1.148.0'));
      expect(info.headers['sign'], pangguaiSign('/user/info', token: 'T1', timestamp: info.headers['timestamp']!));
      final create = kit.fake.requests.firstWhere((request) => request.path == '/trade/create');
      expect((create.headers['imei'], create.headers['categorycode'], create.headers['lat'], create.headers['lng']), ('860000000000001', '00', '36.123456', '117.654321'));
      expect(
        create.headers['orderrisksign'],
        pangguaiRiskSign('/trade/create', token: 'T1', timestamp: create.headers['orderRiskTimestamp']!, category: '00', imei: '860000000000001', latitude: '36.123456', longitude: '117.654321'),
      );
      expect(info.headers.containsKey('imei'), isFalse);
    });

    test('业务码 2 是登录失效；别的照写胖乖的原话', () async {
      final kit = _Kit();
      await kit.signIn();
      kit.fake.expired.add('T1');
      await expectLater(kit.service.ongoing(_phone), throwsA(isA<PangguaiException>().having((error) => error.failure, 'failure', PangguaiFailure.notSignedIn)));
      await expectLater(kit.service.signIn(_phone, '0000', dark: false), throwsA(isA<PangguaiException>().having((error) => error.message, 'message', '验证码错误')));
    });

    test('回 405 就停：同一个域名这段时间里不再发任何请求，也不读拦截页', () async {
      final kit = _Kit();
      await kit.signIn();
      kit.fake.blocked.add('/order/list');
      await expectLater(kit.service.ongoing(_phone), throwsA(isA<PangguaiException>().having((error) => error.failure, 'failure', PangguaiFailure.blocked)));
      final before = kit.fake.requests.length;
      await expectLater(kit.service.inspect(_phone, _washer), throwsA(isA<PangguaiException>().having((error) => error.failure, 'failure', PangguaiFailure.blocked)));
      expect(kit.fake.requests.length, before);
    });

    test('请求排队一个接一个发，相邻至少隔 spacing', () async {
      final fake = _FakePangguai();
      final client = PangguaiClient(http: PangguaiHttp(client: fake.client, spacing: const Duration(milliseconds: 80)));
      final watch = Stopwatch()..start();
      await Future.wait([client.needsCaptcha(_phone), client.needsCaptcha(_phone), client.needsCaptcha(_phone)]);
      expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(160));
    });

    test('饮水机合作方：success 才算成，token 是扫码会话过期', () async {
      final fake = _FakePangguai();
      final client = PangguaiClient(http: PangguaiHttp(client: fake.client, spacing: Duration.zero));
      final water = await client.water('T1', _hash);
      expect([for (final tier in await client.rechargeTiers(water)) (tier.id, tier.amount, tier.gift)], [('64950', 1000, 0), ('64953', 10000, 1000)]);
      final stale = decodePangguaiWater(_hash, {...fake.waterScan(), 'token': 'OLD'});
      await expectLater(client.rechargeTiers(stale), throwsA(isA<PangguaiException>().having((error) => error.code, 'code', 'token')));
    });
  });

  group('服务', () {
    test('要人机验证时先过易盾再交给胖乖核对，发码与登录前都问；关掉验证不发码；登录成功才记凭据，多账号切换与退出', () async {
      final kit = _Kit();
      kit.fake.needsCaptcha = true;
      await kit.service.sendCode(_phone, dark: false);
      expect(kit.captcha.shown, 1);
      expect(kit.fake.paths(), ['/common/isNeedCaptcha', '/captcha/checkCaptcha', '/common/sms/sendCode']);
      expect(kit.fake.requests[1].fields, {'suitScene': '3', 'userPhone': _phone, 'validate': 'V-OK'});
      kit.captcha.answer = null;
      await expectLater(kit.service.sendCode(_phone, dark: false), throwsA(isA<PangguaiException>().having((error) => error.failure, 'failure', PangguaiFailure.cancelled)));
      expect(kit.fake.paths().where((path) => path == '/common/sms/sendCode'), hasLength(1));
      expect((await kit.service.state()).accounts, isEmpty);
      kit.captcha.answer = 'V-OK';
      await kit.signIn();
      kit.fake.needsCaptcha = false;
      await kit.signIn(_other);
      var state = await kit.service.state();
      expect(state.active, _other);
      expect([for (final account in state.accounts) (account.phone, account.token, account.name)], [(_other, 'T2', '合成用户'), (_phone, 'T1', '合成用户')]);
      await kit.service.switchTo(_phone);
      await kit.service.signOut(_phone);
      state = await kit.service.state();
      expect((state.active, state.accounts.single.phone), (_other, _other));
    });

    test('下单：先取位置，再按顺序重发详情、档位、试算、下单；价变了不下单交回新价；取不到位置一个请求都不发；下单没等到回复报不确定', () async {
      final kit = _Kit();
      await kit.signIn();
      kit.fake.requests.clear();
      final orderId = await kit.service.place(_phone, goodsId: _dryer, skuId: '2101', minutes: 3, expected: 66);
      expect(kit.fake.paths(), ['/goods/normal/details', '/goods/normal/skus', '/trade/preview/v4', '/trade/create']);
      expect(kit.fake.requests.last.fields['items'], kit.fake.requests[2].fields['items']);
      expect(kit.fake.requests.last.fields['promotions'], '[]');
      expect(kit.fake.requests[2].fields['isAutoSelectPromotion'], '0');
      expect(kit.fake.orders.keys, [orderId]);
      kit.fake.bump = 1;
      await expectLater(kit.service.place(_phone, goodsId: _dryer, skuId: '2101', minutes: 3, expected: 66), throwsA(isA<PangguaiPriceChanged>().having((changed) => changed.price, 'price', 67)));
      expect(kit.fake.orders, hasLength(1));
      kit.fake.bump = 0;
      kit.fake.requests.clear();
      kit.locator.problem = PangguaiLocationProblem.denied;
      await expectLater(kit.service.place(_phone, goodsId: _dryer, skuId: '2101', minutes: 3, expected: 66), throwsA(isA<PangguaiLocationException>()));
      expect(kit.fake.requests, isEmpty);
      expect(kit.locator.asked.last, isTrue);
      kit.locator.problem = null;
      kit.fake.dropped.add('/trade/create');
      await expectLater(kit.service.place(_phone, goodsId: _dryer, skuId: '2101', minutes: 3, expected: 66), throwsA(isA<PangguaiException>().having((error) => error.failure, 'failure', PangguaiFailure.unsure)));
      expect(kit.fake.paths().where((path) => path == '/trade/create'), hasLength(1));
    });

    test('付款前重查订单与金额、只走支付宝渠道；首页的进行中只列使用中与 10 分钟内没付的', () async {
      final kit = _Kit();
      await kit.signIn();
      final first = await kit.service.place(_phone, goodsId: _washer, skuId: '1102', expected: 100);
      expect(await kit.service.prepay(_phone, first, expected: 100), contains('alipay.trade.app.pay'));
      await expectLater(kit.service.prepay(_phone, first, expected: 200), throwsA(isA<PangguaiPriceChanged>()));
      final second = await kit.service.place(_phone, goodsId: _washer, skuId: '1101', expected: 400);
      kit.fake.pay(second);
      await expectLater(kit.service.prepay(_phone, second, expected: 400), throwsA(isA<PangguaiException>()));
      final now = DateTime.utc(2026, 11, 27, 13, 45);
      expect([for (final order in await kit.service.ongoing(_phone, now: now)) order.id], [second, first]);
      expect([for (final order in await kit.service.ongoing(_phone, now: now.add(const Duration(minutes: 10)))) order.id], [second]);
      await kit.service.cancel(_phone, first);
      expect(kit.fake.paths().sublist(kit.fake.paths().length - 2), ['/order/cancel', '/order/hidden']);
      await expectLater(kit.service.cancel(_phone, second), throwsA(isA<PangguaiException>()));
    });

    test('已取消的单（状态 1，自己取消的或没付被胖乖关掉的）：不进首页、不给付、不再发取消（11-28 真机对它取消回 3122）', () async {
      final kit = _Kit();
      await kit.signIn();
      final orderId = await kit.service.place(_phone, goodsId: _washer, skuId: '1102', expected: 100);
      kit.fake.orders[orderId]!['orderStatus'] = 1;
      expect(await kit.service.ongoing(_phone, now: DateTime.utc(2026, 11, 27, 13, 45)), isEmpty);
      await expectLater(kit.service.prepay(_phone, orderId, expected: 100), throwsA(isA<PangguaiException>().having((error) => error.message, 'message', '这一单已取消，重新下单吧')));
      kit.fake.requests.clear();
      await expectLater(kit.service.cancel(_phone, orderId), throwsA(isA<PangguaiException>().having((error) => error.message, 'message', '这一单已经取消了')));
      expect(kit.fake.paths(), ['/order/detail']);
    });

    test('锁机：先重扫拿新会话，核对水种、水卡与余额门槛，参数照契约展开；锁机没等到回复报不确定', () async {
      final kit = _Kit();
      await kit.signIn();
      kit.fake.requests.clear();
      final run = await kit.service.unlock(_phone, _hash, choiceId: '1556', areaId: '6519');
      expect((run.workingId, run.choice.name), ('WORKING1', '常温水'));
      expect(kit.fake.paths(), ['/distributor/scan', '/distributor/unlock']);
      expect(kit.fake.requests.last.fields, {
        'reqMap[imei]': _hash, 'reqMap[accountId]': 'A1', 'reqMap[token]': 'W-S', 'reqMap[washerId]': 'W1', 'reqMap[passagewaySettingId]': '1556',
        'reqMap[passagewaySort]': '3', 'reqMap[chargeAreaId]': '6519', 'reqMap[useIntegral]': '1', 'distributorType': '2', 'scanType': '4', 'token': 'T1',
      });
      await expectLater(kit.service.unlock(_phone, _hash, choiceId: '1557', areaId: '6519'), throwsA(isA<PangguaiException>()));
      kit.fake.waterBalance = 0.2;
      await expectLater(kit.service.unlock(_phone, _hash, choiceId: '1556', areaId: '6519'), throwsA(isA<PangguaiException>().having((error) => error.code, 'code', 'balance')));
      kit.fake.waterBalance = 4.65;
      kit.fake.dropped.add('/distributor/unlock');
      await expectLater(kit.service.unlock(_phone, _hash, choiceId: '1556', areaId: '6519'), throwsA(isA<PangguaiException>().having((error) => error.failure, 'failure', PangguaiFailure.unsure)));
    });

    test('安全存储按外部输入读：坏的整份当没有、坏的一项跳过；清除数据删凭据与最近使用', () async {
      expect(decodePangguaiVault('{').accounts, isEmpty);
      expect(decodePangguaiVault('{"active":"$_phone","accounts":[{"phone":"$_phone","token":"T1","name":"甲"},{"phone":1}]}').accounts.single.token, 'T1');
      final kit = _Kit();
      await kit.signIn();
      await kit.service.inspect(_phone, _washer);
      expect((await kit.service.devices.load(_phone)).single.name, '合成楼-201');
      await kit.service.clearData();
      expect((await kit.service.state()).accounts, isEmpty);
      expect(await kit.service.devices.load(_phone), isEmpty);
    });
  });

  group('页面', () {
    late ToolboxFixture fixture;
    late _Kit kit;

    ToolboxRuntime runtime({ToolboxQrScan? scan}) => ToolboxRuntime.testing(catalog: toolboxCatalog, store: fixture.store, downloads: fixture.manager, scanQrCode: scan, services: {PangguaiService.serviceId: kit.service});

    Future<void> show(WidgetTester tester, Widget page) async {
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: page));
      await _settle(tester);
    }

    setUp(() async {
      fixture = ToolboxFixture();
      await fixture.initialize();
      kit = _Kit();
    });
    tearDown(() => fixture.close());

    testWidgets('没登录时是登录表单：先同意，要人机验证时先弹验证再发码，60 秒后才能再发，登录后是账号卡', (tester) async {
      kit.fake.needsCaptcha = true;
      await show(tester, PangguaiPage(runtime: runtime()));
      await tester.enterText(find.widgetWithText(TextField, '胖乖生活手机号'), _phone);
      await tester.tap(find.text('获取验证码'));
      await _settle(tester);
      expect(find.text('使用胖乖生活'), findsOneWidget);
      await tester.tap(find.text('同意并继续'));
      await _settle(tester);
      expect((kit.captcha.shown, kit.fake.paths().last), (1, '/common/sms/sendCode'));
      expect(find.textContaining('秒后重发'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, '短信验证码'), _code);
      await tester.tap(find.text('登录'));
      await _settle(tester);
      expect(find.text('合成用户'), findsOneWidget);
      expect(find.text('138****0001'), findsOneWidget);
      expect(find.text('附近门店'), findsOneWidget);
      expect(await tester.runAsync(() => fixture.store.consent(PangguaiService.serviceId, PangguaiService.consentVersion)), isTrue);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('洗衣机：选程序后按钮写服务端的实付，下单换成订单页并开始付，付好是使用中、写预计几点结束', (tester) async {
      await tester.runAsync(kit.signIn);
      kit.alipay.onPay = () => kit.fake.pay(kit.fake.orders.keys.single);
      await show(tester, PangguaiDevicePage(service: kit.service, phone: _phone, goodsId: _washer));
      expect(find.text('合成楼-201'), findsOneWidget);
      expect(find.text('选好再下单'), findsOneWidget);
      await tester.tap(find.text('桶自洁'));
      await _settle(tester);
      expect(find.text('下单并付款 ¥1.00'), findsOneWidget);
      await tester.tap(find.text('下单并付款 ¥1.00'));
      await _settle(tester);
      await _settle(tester);
      expect(kit.alipay.paid, hasLength(1));
      expect(find.text('使用中'), findsOneWidget);
      expect(find.byWidgetPredicate((widget) => widget is DotSeparatedText && widget.text.startsWith('预计 21:44 结束 · ')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('从最近使用打开设备、下单付款后返回：首页进行中的那单是使用中（设备页换成订单页时首页已经刷新过一次）', (tester) async {
      await tester.runAsync(kit.signIn);
      await tester.runAsync(() => kit.service.inspect(_phone, _dryer));
      kit.fake.createdAt = _beijingNow();
      kit.alipay.onPay = () => kit.fake.pay(kit.fake.orders.keys.single);
      await show(tester, PangguaiPage(runtime: runtime()));
      expect(find.byIcon(CampusIcons.dryer), findsOneWidget);
      await tester.tap(find.text('合成楼3层吹风'));
      await _settle(tester);
      await tester.tap(find.text('左边1号'));
      await _settle(tester);
      await tester.tap(find.text('3 分钟 ¥0.66'));
      await _settle(tester);
      await tester.tap(find.text('下单并付款 ¥0.66'));
      await _settle(tester);
      await _settle(tester);
      expect(find.text('使用中'), findsOneWidget);
      await tester.tap(find.byTooltip('返回').last);
      await _settle(tester);
      expect(find.byWidgetPredicate((widget) => widget is DotSeparatedText && widget.text.startsWith('使用中 · ')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('支付宝里取消：回到能再付的样子；⋯ 里取消订单先确认', (tester) async {
      await tester.runAsync(kit.signIn);
      kit.fake.createdAt = _beijingNow();
      final orderId = (await tester.runAsync(() => kit.service.place(_phone, goodsId: _washer, skuId: '1102', expected: 100)))!;
      kit.alipay.status = '6001';
      await show(tester, PangguaiPage(runtime: runtime()));
      expect(_dotted('待付款 · ¥1.00'), findsOneWidget);
      await tester.tap(find.text('合成楼-201'));
      await _settle(tester);
      await tester.tap(find.text('用支付宝付 ¥1.00'));
      await _settle(tester);
      expect(find.text('已取消付款'), findsOneWidget);
      expect(find.text('用支付宝付 ¥1.00'), findsOneWidget);
      await tester.tap(find.byTooltip('更多'));
      await _settle(tester);
      await tester.tap(find.text('取消订单').last);
      await _settle(tester);
      await tester.tap(find.text('取消订单').last);
      await _settle(tester);
      expect(kit.fake.orders.containsKey(orderId), isFalse);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('订单页：付款时胖乖把单关了（变成已取消）原地写已取消，不当成付好了，不再给付也没有⋯；付款区不是提示条锚点', (tester) async {
      await tester.runAsync(kit.signIn);
      final orderId = (await tester.runAsync(() => kit.service.place(_phone, goodsId: _washer, skuId: '1102', expected: 100)))!;
      kit.alipay.onPay = () => kit.fake.orders[orderId]!['orderStatus'] = 1;
      await show(tester, PangguaiOrderPage(service: kit.service, phone: _phone, orderId: orderId, autoPay: true));
      await _settle(tester);
      expect(kit.alipay.paid, hasLength(1));
      expect(find.text('已取消'), findsOneWidget);
      for (final gone in [find.text('使用中'), find.textContaining('用支付宝付'), find.byTooltip('更多')]) {
        expect(gone, findsNothing);
      }
      expect(find.byType(CampusToastAnchor), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('被占用的档位照样列出、标「暂不可用」、点不了：吹风机能选的只剩一个位置时直接选上、位置那行照样显示；洗衣机的程序同样', (tester) async {
      await tester.runAsync(kit.signIn);
      kit.fake.skus[_dryer]![0]['stockState'] = 0;
      await show(tester, PangguaiDevicePage(service: kit.service, phone: _phone, goodsId: _dryer));
      CampusGlassChip chip(String label) => tester.widget<CampusGlassChip>(find.widgetWithText(CampusGlassChip, label));
      expect((chip('左边1号 暂不可用').unavailable, chip('左边1号 暂不可用').selected, chip('右边2号').unavailable, chip('右边2号').selected), (true, false, false, true));
      expect(find.text('下单并付款 ¥0.66'), findsOneWidget);
      await tester.tap(find.text('左边1号 暂不可用'));
      await _settle(tester);
      expect(chip('右边2号').selected, isTrue);
      expect(find.byType(CampusToastAnchor), findsNothing);
      kit.fake.skus[_washer]![0]['stockState'] = 0;
      await show(tester, PangguaiDevicePage(key: const ValueKey('washer'), service: kit.service, phone: _phone, goodsId: _washer));
      expect(_dotted('暂不可用 · 约 35 分钟 · ¥4.00 · 标准洗说明'), findsOneWidget);
      expect(find.text('下单并付款 ¥1.00'), findsOneWidget);
      await tester.tap(find.text('标准洗'));
      await _settle(tester);
      expect(find.text('下单并付款 ¥1.00'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('吹风机：先选位置再选时长，关着的时长不列；只有一个时长的位置直接选好', (tester) async {
      await tester.runAsync(kit.signIn);
      await show(tester, PangguaiDevicePage(service: kit.service, phone: _phone, goodsId: _dryer));
      expect(find.text('先选位置'), findsOneWidget);
      await tester.tap(find.text('左边1号'));
      await _settle(tester);
      expect(find.text('7 分钟 ¥1.20'), findsNothing);
      expect(find.text('选好再下单'), findsOneWidget);
      await tester.tap(find.text('3 分钟 ¥0.66'));
      await _settle(tester);
      expect(find.text('下单并付款 ¥0.66'), findsOneWidget);
      await tester.tap(find.text('右边2号'));
      await _settle(tester);
      expect(find.text('下单并付款 ¥0.66'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('不能用的设备写原因、不给下单；下单要位置：没权限原地写明并给「去设置」', (tester) async {
      await tester.runAsync(kit.signIn);
      await show(tester, PangguaiDevicePage(service: kit.service, phone: _phone, goodsId: _offline));
      expect(find.textContaining('4204'), findsOneWidget);
      expect(find.textContaining('下单'), findsNothing);
      kit.locator.problem = PangguaiLocationProblem.denied;
      await show(tester, PangguaiDevicePage(key: const ValueKey('washer'), service: kit.service, phone: _phone, goodsId: _washer));
      await tester.tap(find.text('标准洗'));
      await _settle(tester);
      await tester.tap(find.text('下单并付款 ¥4.00'));
      await _settle(tester);
      expect(find.text('下单要用手机位置：要允许使用位置'), findsOneWidget);
      await tester.tap(find.text('去设置'));
      await _settle(tester);
      expect(kit.locator.opened, [PangguaiLocationProblem.denied]);
      expect(kit.fake.orders, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('饮水机：默认常温水，开始取水后按状态提示，结束后点「好了」回来；余额不够不给取水；充值档位点了才读', (tester) async {
      await tester.runAsync(kit.signIn);
      await show(tester, PangguaiWaterPage(service: kit.service, phone: _phone, hash: _hash));
      expect(find.text('¥4.65'), findsOneWidget);
      // 出不了的水种是虚线空心的「暂不可用」，不是压淡一点的普通标签；选择卡不是提示条锚点（提示条会压住上面的设备卡）。
      expect(tester.widget<CampusGlassChip>(find.widgetWithText(CampusGlassChip, '冰水 暂不可用')).unavailable, isTrue);
      expect(find.byType(CampusToastAnchor), findsNothing);
      expect(kit.fake.paths().contains('/ewash/api/scanLd/getLdRechargeGift.json'), isFalse);
      await tester.tap(find.text('开始取水'));
      await _settle(tester);
      expect(find.text('按机器上闪灯的按钮出水，再按一次停止'), findsOneWidget);
      kit.fake.waterState = 5;
      await tester.pump(const Duration(seconds: 4));
      await _settle(tester);
      expect(find.text('这次取水结束了，费用稍后从水卡扣'), findsOneWidget);
      await tester.tap(find.text('好了'));
      await _settle(tester);
      expect(find.text('开始取水'), findsOneWidget);
      await tester.tap(find.text('充值'));
      await _settle(tester);
      expect(find.text('¥100.00 送 ¥10.00'), findsOneWidget);
      kit.fake.waterBalance = 0.1;
      await tester.pumpWidget(const SizedBox());
      await show(tester, PangguaiWaterPage(key: const ValueKey('short'), service: kit.service, phone: _phone, hash: _hash));
      expect(find.text('不到 ¥0.30，先充值'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.ancestor(of: find.text('开始取水'), matching: find.byType(FilledButton))).onPressed, isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('首页：凭据失效时原地重新登录这个账号，手机号不能改；扫码直接换成设备页', (tester) async {
      await tester.runAsync(kit.signIn);
      Future<String?> scan(BuildContext context, String hint, String? Function(String raw) accept, {Widget Function(String raw)? then}) async {
        expect(accept('https://example.com'), isNotNull);
        const raw = 'https://h5.qiekj.com/skip?NQT=$_nqt';
        expect(accept(raw), isNull);
        await Navigator.of(context).push<void>(CampusPageRoute(builder: (_) => then!(raw)));
        return null;
      }

      await show(tester, PangguaiPage(runtime: runtime(scan: scan)));
      await tester.tap(find.text('扫码'));
      await _settle(tester);
      expect(find.text('合成楼-201'), findsOneWidget);
      expect(kit.fake.requests.any((request) => request.path == '/goods/scan/v2' && request.fields['NQT'] == _nqt), isTrue);
      await tester.tap(find.byTooltip('返回').last);
      await _settle(tester);
      kit.fake.expired.add('T1');
      await tester.pumpWidget(const SizedBox());
      await show(tester, PangguaiPage(key: const ValueKey('again'), runtime: runtime()));
      expect(find.text('登录过期了，请重新登录'), findsOneWidget);
      final phone = tester.widget<TextField>(find.widgetWithText(TextField, '胖乖生活手机号'));
      expect(phone.controller!.text, _phone);
      expect(phone.enabled, isFalse);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('附近门店：按位置列门店（距离、空闲几台），点进门店看设备状态，再点进设备页', (tester) async {
      await tester.runAsync(kit.signIn);
      await show(tester, PangguaiPage(runtime: runtime()));
      await tester.tap(find.text('附近门店'));
      await _settle(tester);
      expect(_dotted('1.3 公里 · 空闲 19/20 台'), findsOneWidget);
      expect(find.text('合成门店'), findsOneWidget);
      await tester.tap(find.text('合成门店'));
      await _settle(tester);
      expect(_dotted('空闲'), findsOneWidget);
      expect(_dotted('使用中 · 还剩 21分钟'), findsOneWidget);
      await tester.tap(find.text('合成楼-201'));
      await _settle(tester);
      expect(find.text('标准洗'), findsOneWidget);
      final shops = kit.fake.requests.firstWhere((request) => request.path == '/shop/nearby/list');
      expect((shops.fields['latitude'], shops.fields['longitude'], shops.fields['pageSize']), ('36.123456', '117.654321', '10'));
      await tester.pumpWidget(const SizedBox());
    });

    test('生活登记了胖乖生活：开关 toolbox.life.pangguai 关着不显示、路由回到生活；开着才显示', () {
      final closed = ToolboxRuntime.testing(catalog: toolboxCatalog, store: fixture.store, downloads: fixture.manager, features: _Gate({}));
      final life = closed.modules.singleWhere((module) => module.id == 'life');
      final pangguai = life.children.singleWhere((child) => child.id == PangguaiService.serviceId);
      expect((pangguai.flag?.id, pangguai.flag?.fallback, pangguai.clearedData.isNotEmpty), ('toolbox.life.pangguai', false, true));
      expect(featureFlags, contains(pangguaiFlag));
      expect(toolboxVisible(pangguai, features: closed.features), isFalse);
      expect(toolboxRedirect([life], '/toolbox/life/pangguai', features: closed.features), '/toolbox/life');
      final open = _Gate({'toolbox.life.pangguai'});
      expect(toolboxVisible(pangguai, features: open), isTrue);
      expect(toolboxRedirect([life], '/toolbox/life/pangguai', features: open), isNull);
    });
  });
}

Finder _dotted(String text) => find.byWidgetPredicate((widget) => widget is DotSeparatedText && widget.text == text);

// 此刻的北京时间写法（假胖乖的订单时刻用，同胖乖协议）。
String _beijingNow() => DateTime.now().toUtc().add(const Duration(hours: 8)).toIso8601String().substring(0, 19).replaceFirst('T', ' ');

// 让假服务端（真实异步）与界面都走完：按真实时间等一小会儿再推一帧，最多约 2 秒。
Future<void> _settle(WidgetTester tester) async {
  for (var index = 0; index < 20; index++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}
