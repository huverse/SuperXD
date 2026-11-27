import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:superxd/domain/feature_flags.dart';
import 'package:superxd/theme/campus_glass_controls.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/dot_separated_text.dart';
import 'package:superxd/toolbox/life/life_alipay.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_client.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_device_page.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_devices.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_http.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_location.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_models.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_order_page.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_page.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_service.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_vault.dart';
import 'package:superxd/toolbox/life/pangguai/pangguai_web_page.dart';
import 'package:superxd/toolbox/toolbox_catalog.dart';
import 'package:superxd/toolbox/toolbox_module.dart';
import 'package:superxd/toolbox/toolbox_runtime.dart';

import 'toolbox_test_support.dart';

// 胖乖生活（人工决策见 lib/toolbox/life/pangguai/pangguai_service.dart 文件头）：协议、服务与页面。数据全是合成的。

const _phone = '13800000001', _other = '13800000002', _code = '2468';

// 胖乖的北京时间字符串（协议写法）。
String _beijing(DateTime instant) {
  final local = instant.toUtc().add(const Duration(hours: 8));
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

// 内存里的假胖乖：按路径回合成数据；记下每次请求的路径、表单与请求头。下单要求同一个凭据先取过这台设备的详情与档位（同真实服务端的「设备选择态」）。
class _FakePangguai {
  final requests = <http.Request>[];
  final tokens = <String, String>{};
  var needsCaptcha = false;
  var blocked = false;
  // 试算时在标价上加多少分（模拟价变了）。
  var previewExtra = 0;
  final selected = <String, List<String>>{};
  final orders = <String, Map<String, Object?>>{};
  var nextOrder = 1;

  static final skus = {
    '9001': [
      {'skuId': 11, 'name': '超净洗', 'feature': '适用比较脏的衣物', 'price': '5.00', 'unit': '45'},
      {'skuId': 12, 'name': '标准洗', 'feature': '适合常规衣物', 'price': '4.00', 'unit': '35'},
      {'skuId': 13, 'name': '单脱', 'feature': '适用衣物脱水', 'price': '1.00', 'unit': '5'},
      {'skuId': 14, 'name': '桶自洁', 'feature': '设备桶自洁', 'price': '1.00', 'discountPrice': '0.00', 'unit': '2'},
    ],
    '9002': [
      {'skuId': 21, 'name': '左边1号', 'price': '0.22', 'unit': '1', 'extAttr': jsonEncode({'perPrice': [{'time': '5', 'price': '1'}, {'time': '3', 'price': '0.66'}, {'time': '7', 'price': '1.2', 'status': false}]})},
      {'skuId': 22, 'name': '右边2号', 'price': '0.2', 'unit': '1', 'extAttr': jsonEncode({'perPrice': [{'time': '3', 'price': '0.66'}, {'time': '5', 'price': '1'}]})},
    ],
    '9003': [
      {'skuId': 31, 'name': '烘干', 'price': '3.00', 'discountPrice': '2.50', 'unit': '40'},
    ],
  };

  static Map<String, Object?> device(String goodsId) => switch (goodsId) {
    '9001' => {'goodsId': 9001, 'name': '合成楼-101', 'categoryCode': '00', 'payment': 'before', 'imei': '860000000000001', 'orgId': 100001, 'orgName': '合成学院', 'shopId': 'S0001', 'deviceErrorCode': null},
    '9002' => {'goodsId': 9002, 'name': '合成楼3层吹风', 'categoryCode': '03', 'payment': 'before', 'imei': '860000000000002', 'orgId': 100002, 'orgName': '合成公寓', 'shopId': 'S0002', 'deviceErrorCode': null},
    '9003' => {'goodsId': 9003, 'name': '合成楼-烘干', 'categoryCode': '02', 'payment': 'before', 'imei': '860000000000003', 'orgId': 100001, 'orgName': '合成学院', 'deviceErrorCode': null},
    '9004' => {'goodsId': 9004, 'name': '合成饮水机', 'categoryCode': '04', 'payment': 'after', 'imei': '860000000000004', 'orgId': 100001, 'orgName': '合成学院', 'deviceErrorCode': null},
    _ => {'goodsId': 9005, 'name': '合成楼-102', 'categoryCode': '00', 'payment': 'before', 'imei': '860000000000005', 'orgId': 100001, 'orgName': '合成学院', 'deviceErrorCode': '4204'},
  };

  int count(String path) => requests.where((request) => request.url.path == path).length;
  List<String> get paths => [for (final request in requests) request.url.path];
  Map<String, String> last(String path) => requests.lastWhere((request) => request.url.path == path).bodyFields;
  http.Request lastRequest(String path) => requests.lastWhere((request) => request.url.path == path);

  // 付好一单：胖乖付款成功就写上预计结束时刻（付款时刻加时长）并显示重新启动。
  void pay(String orderId) {
    final order = orders[orderId]!;
    final now = DateTime.now().toUtc();
    order
      ..['orderStatus'] = 2
      ..['payTime'] = _beijing(now)
      ..['completeTime'] = _beijing(now.add(Duration(minutes: order['markMinutes']! as int)))
      ..['showStart'] = true;
  }

  late final client = MockClient((request) async {
    requests.add(request);
    if (blocked) return http.Response('<html>blocked</html>', 405);
    final fields = request.bodyFields;
    final token = fields['token'];
    Map<String, Object?> ok(Object? data) => {'code': 0, 'msg': '成功', 'data': data};
    Map<String, Object?> fail(int code, [String? message]) => {'code': code, 'msg': message, 'data': null};
    final Map<String, Object?> reply;
    if (const {'/common/isNeedCaptcha', '/common/sms/sendCode', '/user/reg'}.contains(request.url.path)) {
      reply = switch (request.url.path) {
        '/common/isNeedCaptcha' => ok(needsCaptcha),
        '/common/sms/sendCode' => ok(null),
        _ when fields['verify'] == _code => ok({'token': tokens[fields['phone']!] = 'TOKEN-${fields['phone']}-${tokens.length}', 'newRegister': false}),
        _ => fail(1, '验证码错误'),
      };
    } else if (token == null || !tokens.containsValue(token) || request.headers['Authorization'] != token) {
      reply = fail(2, '未登录');
    } else {
      final trail = selected.putIfAbsent(token, () => []);
      reply = switch (request.url.path) {
        '/user/info' => ok({'id': 'U1', 'userName': '合成同学', 'phone': '138****0001', 'balance': '0.00'}),
        '/goods/scan/v2' => fields['NQT'] == 'abcd-1234' ? ok({'id': '9001', 'categoryCode': '00', 'categoryName': '洗衣机'}) : fail(100000, '[0]'),
        '/goods/normal/details' => () {
          trail
            ..clear()
            ..add('details:${fields['goodsId']}');
          return ok(device(fields['goodsId']!));
        }(),
        '/goods/normal/skus' => () {
          trail.add('skus:${fields['goodsId']}');
          return ok(skus[fields['goodsId']] ?? const []);
        }(),
        '/trade/check_device_status' => ok({'msgId': '1', 'faultDesc': null, 'health': true}),
        '/trade/preview/v4' => () {
          final item = (jsonDecode(fields['items']!) as List).single as Map;
          return ok({'realPrice': _price(item['goodsId'] as String, item['skuId'] as String, int.parse(item['amount'] as String), extra: previewExtra)});
        }(),
        '/trade/create' => () {
          final item = (jsonDecode(fields['items']!) as List).single as Map;
          if (!trail.contains('details:${item['goodsId']}') || !trail.contains('skus:${item['goodsId']}')) return fail(-1, '下单异常，请稍后再试');
          trail.clear();
          final orderId = '01202611270000000000${nextOrder++}';
          final sku = skus[item['goodsId']]!.firstWhere((sku) => '${sku['skuId']}' == item['skuId']);
          orders[orderId] = {
            'id': orderId,
            'orderNo': orderId,
            'orderStatus': 1,
            'createTime': _beijing(DateTime.now()),
            'payTime': null,
            'completeTime': null,
            'showStart': false,
            'markPrice': _price(item['goodsId'] as String, item['skuId'] as String, int.parse(item['amount'] as String)),
            'markMinutes': item['amount'] == '1' ? int.parse(sku['unit']! as String) : int.parse(item['amount'] as String),
            'machineFunctionName': sku['name'],
            'goodsName': device(item['goodsId'] as String)['name'],
          };
          return ok({'tradeType': 1, 'tradeNo': orderId, 'orderId': orderId});
        }(),
        '/payChannelRoute/againPay' => ok([{'method': 13, 'methodName': '支付宝', 'defaultFlag': true, 'useStatus': true}, {'method': 2, 'methodName': '余额支付', 'useStatus': false}]),
        '/pay/unify/prePay' => ok({'exist': false, 'prepayParam': 'app_id=2021000000000000&method=alipay.trade.app.pay&biz_content=%7B%22out_trade_no%22%3A%22${fields['orderNo']}%22%7D&sign=x'}),
        '/order/detail' => orders[fields['orderId']] == null ? fail(-1, '订单不存在') : ok(orders[fields['orderId']]),
        '/order/list' => ok({'items': orders.values.toList().reversed.toList()}),
        '/order/cancel' => ok(null),
        '/order/hidden' => () {
          orders.remove(fields['orderId']);
          return ok(null);
        }(),
        '/trade/order/start' => ok(null),
        '/shop/nearby/list' => ok({'items': [{'id': 'S0001', 'orgId': 100001, 'name': '合成学院洗衣房', 'address': '合成路 1 号', 'distance': '86.4', 'machineCount': 12}]}),
        '/appointNew/newNearByList' => ok([{'machineTypeId': '00', 'machineTypeName': '洗衣'}, {'machineTypeId': '03', 'machineTypeName': '吹风'}]),
        '/appointNew/near/newMachines' => ok({'items': fields['machineTypeId'] == '00' ? [{'goodsId': 9001, 'goodsName': '合成楼-101'}] : [{'goodsId': 9002, 'goodsName': '合成楼3层吹风'}]}),
        _ => fail(-1),
      };
    }
    return http.Response.bytes(utf8.encode(jsonEncode(reply)), 200, headers: {'content-type': 'application/json'});
  });

  // 胖乖算的价（元的文本）：洗衣机按程序价，吹风机、烘干机按时长档。
  static String _price(String goodsId, String skuId, int amount, {int extra = 0}) {
    final sku = skus[goodsId]!.firstWhere((sku) => '${sku['skuId']}' == skuId);
    final tiers = sku['extAttr'] == null ? const <Object?>[] : (jsonDecode(sku['extAttr']! as String) as Map)['perPrice'] as List;
    final yuan = tiers.isEmpty
        ? (sku['discountPrice'] != null && sku['discountPrice'] != '0.00' ? sku['discountPrice']! : sku['price']!) as String
        : (tiers.firstWhere((tier) => tier['time'] == '$amount') as Map)['price'] as String;
    final cents = (double.parse(yuan) * 100).round() + extra;
    return '${cents ~/ 100}.${(cents % 100).toString().padLeft(2, '0')}';
  }
}

// 假支付宝：付款时由测试决定结果码（9000 付好时顺手让假胖乖记成已付）。
class _FakeAlipay implements LifeAlipay {
  _FakeAlipay(this.fake);
  final _FakePangguai fake;
  var status = '9000';
  final paid = <String>[];

  @override
  Future<String> pay(String orderContent) async {
    final orderId = RegExp(r'out_trade_no%22%3A%22(\d+)').firstMatch(orderContent)![1]!;
    paid.add(orderId);
    if (status == '9000') fake.pay(orderId);
    return status;
  }
}

class _FakeLocator implements PangguaiLocator {
  PangguaiLocateFailure? failure;
  final asked = <bool>[];
  final opened = <PangguaiLocateFailure>[];

  @override
  Future<PangguaiPosition> locate({required bool ask}) async {
    asked.add(ask);
    if (failure case final failure?) throw PangguaiLocateException(failure);
    return (latitude: 36.123456, longitude: 117.654321);
  }

  @override
  Future<void> openSettings(PangguaiLocateFailure failure) async => opened.add(failure);
}

PangguaiService _service(_FakePangguai fake, {_FakeLocator? locator, _FakeAlipay? alipay, PangguaiVault? vault}) => PangguaiService(
  vault: vault ?? MemoryPangguaiVault(),
  devices: PangguaiDeviceStore.memory(),
  client: PangguaiClient(client: fake.client, spacing: Duration.zero),
  alipay: alipay ?? _FakeAlipay(fake),
  locator: locator ?? _FakeLocator(),
);

Future<void> _settle(WidgetTester tester) async {
  for (var index = 0; index < 20; index++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

bool _dotted(Widget widget, String text) => widget is DotSeparatedText && widget.text == text;

void main() {
  group('协议', () {
    test('扫到的码：NQT、IMEI、SN 交给扫码接口（同官方的先后），apwork.cn 的饮水机码取 ? 后面整段，别的不认', () {
      final washer = pangguaiParseCode('https://h5.qiekj.com/skip?NQT=abcd-1234-ef56') as PangguaiGoodsCode;
      expect((washer.key, washer.value), ('NQT', 'abcd-1234-ef56'));
      final hair = pangguaiParseCode('https://h5.qiekj.com/skip?Company=qiekj&CommunicateType=1&Ver=4&NQT=9b0f-0000') as PangguaiGoodsCode;
      expect((hair.key, hair.value), ('NQT', '9b0f-0000'));
      expect((pangguaiParseCode('https://h5.qiekj.com/skip?IMEI=860000000000001') as PangguaiGoodsCode).key, 'IMEI');
      expect((pangguaiParseCode('https://h5.qiekj.com/skip?SN=A1B2C3') as PangguaiGoodsCode).key, 'SN');
      expect((pangguaiParseCode('http://apwork.cn/scan/qie?ABCDEF0123456789ABCDEF0123456789') as PangguaiWaterCode).imei, 'ABCDEF0123456789ABCDEF0123456789');
      expect(pangguaiParseCode('https://example.com/?x=1'), isNull);
      expect(pangguaiParseCode('http://apwork.cn/scan/qie?<script>'), isNull);
      expect(pangguaiParseCode('随便一段字'), isNull);
    });

    test('凭据同时放在请求头 Authorization 与表单 token，带 Version 与 channel，不带签名与设备号', () async {
      final fake = _FakePangguai()..tokens[_phone] = 'TOKEN-1';
      final client = PangguaiClient(client: fake.client, spacing: Duration.zero);
      expect((await client.user('TOKEN-1')).name, '合成同学');
      final request = fake.lastRequest('/user/info');
      expect(request.bodyFields['token'], 'TOKEN-1');
      expect(request.headers['Authorization'], 'TOKEN-1');
      expect((request.headers['Version'], request.headers['channel']), ('1.148.0', 'android_app'));
      expect(request.headers.keys.map((key) => key.toLowerCase()), isNot(anyOf(contains('sign'), contains('deviceid'), contains('orderrisksign'))));
      expect(request.method, 'POST');
      expect(request.url.toString(), 'https://userapi.qiekj.com/user/info');
    });

    test('业务码：2 是没登录、2128 是有没付的单、100000 写设备不存在、别的照写原话', () async {
      Future<PangguaiException> reply(Map<String, Object?> body) async {
        final transport = PangguaiHttp(client: MockClient((_) async => _json(body)), spacing: Duration.zero);
        try {
          await transport.post('/x', const {});
        } on PangguaiException catch (error) {
          return error;
        }
        fail('没抛');
      }

      expect((await reply({'code': 2, 'msg': '未登录'})).failure, PangguaiFailure.notSignedIn);
      expect((await reply({'code': 2128, 'msg': '您有未支付的订单'})).message, '您有未支付的订单');
      expect((await reply({'code': 2128, 'msg': '您有未支付的订单'})).failure, PangguaiFailure.unpaid);
      expect((await reply({'code': 100000, 'msg': '[999]'})).message, '设备不存在');
      expect((await reply({'code': -1, 'msg': '下单异常，请稍后再试'})).message, '下单异常，请稍后再试');
      expect((await reply({'code': -1, 'msg': null})).message, '胖乖生活没有办成（-1）');
    });

    test('防火墙拦下（405）：停住一段时间不再发请求，依次等 5、15 分钟，中间成功一次就从头算', () async {
      var now = DateTime.utc(2026, 11, 27, 8);
      final fake = _FakePangguai()..tokens[_phone] = 'TOKEN-1';
      final transport = PangguaiHttp(client: fake.client, spacing: Duration.zero, clock: () => now);
      fake.blocked = true;
      await expectLater(transport.post('/user/info', const {}, token: 'TOKEN-1'), throwsA(isA<PangguaiException>().having((error) => error.failure, 'failure', PangguaiFailure.blocked).having((error) => error.message, 'message', contains('5 分钟'))));
      final sent = fake.requests.length;
      now = now.add(const Duration(minutes: 3));
      await expectLater(transport.post('/user/info', const {}, token: 'TOKEN-1'), throwsA(isA<PangguaiException>().having((error) => error.message, 'message', contains('2 分钟'))));
      expect(fake.requests.length, sent, reason: '拦着的时候一个请求都不发');
      now = now.add(const Duration(minutes: 3));
      await expectLater(transport.post('/user/info', const {}, token: 'TOKEN-1'), throwsA(isA<PangguaiException>().having((error) => error.message, 'message', contains('15 分钟'))));
      now = now.add(const Duration(minutes: 16));
      fake.blocked = false;
      await transport.post('/user/info', const {}, token: 'TOKEN-1');
      fake.blocked = true;
      await expectLater(transport.post('/user/info', const {}, token: 'TOKEN-1'), throwsA(isA<PangguaiException>().having((error) => error.message, 'message', contains('5 分钟'))));
    });

    test('同一个服务的请求排队一个接一个发，相邻两次至少隔 spacing', () async {
      final started = <DateTime>[];
      var running = 0, overlap = false;
      final transport = PangguaiHttp(
        client: MockClient((_) async {
          started.add(DateTime.now());
          if (++running > 1) overlap = true;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          running--;
          return _json({'code': 0, 'data': null});
        }),
        spacing: const Duration(milliseconds: 60),
      );
      await Future.wait([for (var index = 0; index < 3; index++) transport.post('/x', const {})]);
      expect(overlap, isFalse);
      for (var index = 1; index < started.length; index++) {
        expect(started[index].difference(started[index - 1]).inMilliseconds, greaterThanOrEqualTo(55));
      }
    });

    test('档位：折扣价是 0 时用原价；时长档按分钟排、status 为 false 的不能选', () {
      final skus = decodePangguaiSkus([..._FakePangguai.skus['9001']!, ..._FakePangguai.skus['9002']!, ..._FakePangguai.skus['9003']!]);
      expect(skus[3].cents, 100, reason: '桶自洁的折扣价是 0.00，按原价');
      expect((skus[0].minutes, skus[0].cents, skus[0].tiers.length), (45, 500, 0));
      expect([for (final tier in skus[4].tiers) (tier.minutes, tier.cents, tier.available)], [(3, 66, true), (5, 100, true), (7, 120, false)]);
      expect(skus[6].cents, 250, reason: '有折扣价用折扣价');
      expect(() => decodePangguaiSkus([{'skuId': 1, 'price': 'abc'}]), throwsA(isA<PangguaiException>()));
    });

    test('订单：北京时间换成 UTC；创建 5 分钟内能付，付款后 3 分钟内能重新启动', () {
      final order = decodePangguaiOrder({
        'id': '0120261127154036151559',
        'orderNo': '0120261127154036151559',
        'orderStatus': 2,
        'createTime': '2026-11-27 15:40:36',
        'payTime': '2026-11-27 15:41:00',
        'completeTime': '2026-11-27 15:43:00',
        'showStart': true,
        'payPrice': '1.00',
        'markMinutes': 2,
        'machineFunctionName': '桶自洁',
      });
      expect(order.createdAt, DateTime.utc(2026, 11, 27, 7, 40, 36));
      expect(order.endsAt, DateTime.utc(2026, 11, 27, 7, 43));
      expect((order.cents, order.minutes, order.function), (100, 2, '桶自洁'));
      expect(order.restartable(DateTime.utc(2026, 11, 27, 7, 43, 59)), isTrue);
      expect(order.restartable(DateTime.utc(2026, 11, 27, 7, 44, 1)), isFalse);
      final unpaid = decodePangguaiOrder({'orderNo': '1', 'orderStatus': 1, 'createTime': '2026-11-27 15:40:36', 'markPrice': '5.00'});
      expect(unpaid.payable(DateTime.utc(2026, 11, 27, 7, 45, 35)), isTrue);
      expect(unpaid.payable(DateTime.utc(2026, 11, 27, 7, 45, 37)), isFalse);
      expect(unpaid.cents, 500);
    });

    test('预支付只认支付宝 APP 支付串', () {
      expect(decodePangguaiAlipayOrder({'prepayParam': 'app_id=1&method=alipay.trade.app.pay&sign=x'}), contains('alipay.trade.app.pay'));
      expect(() => decodePangguaiAlipayOrder({'prepayParam': 'weixin://pay'}), throwsA(isA<PangguaiException>()));
      expect(() => decodePangguaiAlipayOrder({'prepayParam': null}), throwsA(isA<PangguaiException>()));
    });

    test('饮水机网页：带上设备号与凭据打开胖乖的页面；只停在胖乖与支付宝的网页，拉起支付宝、微信的交给系统', () {
      final page = PangguaiWaterPage.page('ABCDEF0123456789', 'TOKEN-1');
      expect(page.toString(), 'https://h5.qiekj.com/black/?companyType=apwork&IMEI=ABCDEF0123456789&token=TOKEN-1');
      expect(pangguaiWebAllowed(Uri.parse('https://h5user.qiekj.com/vip')), isTrue);
      expect(pangguaiWebAllowed(Uri.parse('https://mclient.alipay.com/cashier')), isTrue);
      expect(pangguaiWebAllowed(Uri.parse('https://example.com/qiekj.com')), isFalse);
      expect(pangguaiWebAllowed(Uri.parse('https://qiekj.com.example.com/')), isFalse);
      expect(pangguaiWebExternal(Uri.parse('alipays://platformapi/startapp')), isTrue);
      expect(pangguaiWebExternal(Uri.parse('intent://x')), isFalse);
    });

    test('账号存储按外部输入读：坏了整份当没有，坏的那一项跳过', () {
      expect(decodePangguaiVault('{').accounts, isEmpty);
      final state = decodePangguaiVault(jsonEncode({'active': _other, 'accounts': [{'phone': _phone, 'token': 'A'}, {'phone': 3}, {'phone': _other, 'token': 'B'}]}));
      expect([for (final account in state.accounts) account.phone], [_phone, _other]);
      expect(state.current!.token, 'B');
    });
  });

  group('服务', () {
    test('登录才记凭据；多账号切换、退出删掉它的凭据与最近使用；没有凭据时请先登录', () async {
      final fake = _FakePangguai();
      final service = _service(fake);
      await expectLater(service.run(_phone, (token) async => token), throwsA(isA<PangguaiException>().having((error) => error.failure, 'failure', PangguaiFailure.notSignedIn)));
      await expectLater(service.signIn(_phone, '0000'), throwsA(isA<PangguaiException>()));
      expect((await service.state()).accounts, isEmpty);
      await service.signIn(_phone, _code);
      await service.signIn(_other, _code);
      expect((await service.state()).current!.phone, _other);
      await service.switchTo(_phone);
      expect((await service.state()).current!.phone, _phone);
      await service.inspect(_phone, '9001');
      expect(await service.devices.recent(_phone), hasLength(1));
      await service.signOut(_phone);
      expect((await service.state()).current!.phone, _other);
      expect(await service.devices.recent(_phone), isEmpty);
      await service.clearData();
      expect((await service.state()).accounts, isEmpty);
    });

    test('胖乖要图形验证时不发短信，原地写明', () async {
      final fake = _FakePangguai()..needsCaptcha = true;
      await expectLater(_service(fake).sendCode(_phone), throwsA(isA<PangguaiException>().having((error) => error.message, 'message', contains('图形验证'))));
      expect(fake.count('/common/sms/sendCode'), 0);
    });

    test('下单：详情 → 档位 → 试算 → 下单按顺序连着发，设备号、品类与位置放请求头，吹风机的 amount 与 num 是分钟数', () async {
      final fake = _FakePangguai();
      final locator = _FakeLocator();
      final service = _service(fake, locator: locator);
      await service.signIn(_phone, _code);
      fake.requests.clear();
      final placed = await service.place(_phone, goodsId: '9002', item: const PangguaiItem(goodsId: '9002', skuId: '21', amount: 3), expected: 66) as PangguaiPlaced;
      expect(fake.paths, ['/goods/normal/details', '/goods/normal/skus', '/trade/preview/v4', '/trade/create']);
      expect(locator.asked, [true]);
      final create = fake.lastRequest('/trade/create');
      expect((create.headers['imei'], create.headers['categoryCode'], create.headers['lat'], create.headers['lng']), ('860000000000002', '03', '36.123456', '117.654321'));
      expect(jsonDecode(create.bodyFields['items']!), [{'goodsId': '9002', 'skuId': '21', 'amount': '3', 'soldType': '1', 'num': '3'}]);
      expect(create.bodyFields['promotions'], '[]', reason: '第一版不用券');
      expect(fake.last('/trade/preview/v4')['isAutoSelectPromotion'], '0');
      expect(placed.orgId, '100002');
      expect(fake.orders[placed.order.orderId]!['markMinutes'], 3);
    });

    test('试算的价和页面上的不一样时不下单，交回新价；位置取不到照样下单、位置写空', () async {
      final fake = _FakePangguai()..previewExtra = 20;
      final locator = _FakeLocator()..failure = PangguaiLocateFailure.denied;
      final service = _service(fake, locator: locator);
      await service.signIn(_phone, _code);
      final changed = await service.place(_phone, goodsId: '9001', item: const PangguaiItem(goodsId: '9001', skuId: '11'), expected: 500);
      expect((changed as PangguaiPriceChanged).cents, 520);
      expect(fake.count('/trade/create'), 0);
      await service.place(_phone, goodsId: '9001', item: const PangguaiItem(goodsId: '9001', skuId: '11'), expected: 520);
      expect((fake.lastRequest('/trade/create').headers['lat'], fake.lastRequest('/trade/create').headers['lng']), ('', ''));
    });

    test('付款方式只列收银台给了且这一版接了的（支付宝）；不知道门店编号时直接给支付宝', () async {
      final fake = _FakePangguai();
      final service = _service(fake);
      await service.signIn(_phone, _code);
      expect(await service.payMethods(_phone, 'O1', '100001'), [PangguaiPayMethod.alipay]);
      expect(fake.last('/payChannelRoute/againPay'), containsPair('shopId', '100001'));
      fake.requests.clear();
      expect(await service.payMethods(_phone, 'O1', null), [PangguaiPayMethod.alipay]);
      expect(fake.requests, isEmpty);
    });
  });

  group('页面', () {
    late ToolboxFixture fixture;
    late _FakePangguai fake;
    late _FakeLocator locator;
    late _FakeAlipay alipay;
    late PangguaiService service;

    ToolboxRuntime runtime({ToolboxQrScan? scan}) => ToolboxRuntime.testing(catalog: toolboxCatalog, store: fixture.store, downloads: fixture.manager, services: {PangguaiService.serviceId: service}, scanQrCode: scan);

    Future<void> open(WidgetTester tester, Widget page) async {
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: page));
      await _settle(tester);
    }

    Future<void> signIn(WidgetTester tester) => tester.runAsync(() async {
      await fixture.store.grantConsent(PangguaiService.serviceId, PangguaiService.consentVersion);
      await service.signIn(_phone, _code);
    });

    setUp(() async {
      fixture = ToolboxFixture();
      await fixture.initialize();
      fake = _FakePangguai();
      locator = _FakeLocator();
      alipay = _FakeAlipay(fake);
      service = _service(fake, locator: locator, alipay: alipay);
    });
    tearDown(() => fixture.close());

    testWidgets('没登录时是登录表单：发码前先取同意，收码登录后是账号卡、扫码与附近门店', (tester) async {
      await open(tester, PangguaiPage(runtime: runtime(scan: (context, hint, accept, {then}) async => null)));
      await tester.enterText(find.widgetWithText(TextField, '胖乖生活手机号'), _phone);
      await tester.tap(find.text('获取验证码'));
      await _settle(tester);
      expect(find.text('使用胖乖生活'), findsOneWidget);
      await tester.tap(find.text('同意并登录'));
      await _settle(tester);
      expect(fake.count('/common/sms/sendCode'), 1);
      expect(find.textContaining('秒后重发'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, '短信验证码'), _code);
      await tester.tap(find.text('登录'));
      await _settle(tester);
      expect(find.text('合成同学'), findsOneWidget);
      expect(find.text('138****0001'), findsOneWidget);
      expect(find.text('扫码'), findsOneWidget);
      expect(find.text('附近门店'), findsOneWidget);
      expect(await tester.runAsync(() => fixture.store.consent(PangguaiService.serviceId, PangguaiService.consentVersion)), isTrue);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('凭据失效（胖乖回没登录）：首页原地请这个账号重新收短信登录，手机号不能改', (tester) async {
      await signIn(tester);
      fake.tokens.clear();
      await open(tester, PangguaiPage(runtime: runtime()));
      expect(find.text('胖乖生活的登录过期了，请重新登录'), findsOneWidget);
      final phoneField = tester.widget<TextField>(find.widgetWithText(TextField, '胖乖生活手机号'));
      expect((phoneField.controller!.text, phoneField.enabled), (_phone, false));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('洗衣机：选程序 → 下单并付款 → 支付宝付好 → 使用中倒计时到预计结束，3 分钟内能重新启动', (tester) async {
      await signIn(tester);
      await open(tester, PangguaiDevicePage(service: service, phone: _phone, goodsId: '9001'));
      expect(find.text('选程序'), findsOneWidget);
      expect(find.byWidgetPredicate((widget) => _dotted(widget, '约 45 分钟 · ¥5.00 · 适用比较脏的衣物')), findsOneWidget);
      expect(find.text('下单并付款 ¥5.00'), findsOneWidget);
      await tester.tap(find.text('桶自洁'));
      await tester.pump();
      expect(find.text('下单并付款 ¥1.00'), findsOneWidget);
      fake.requests.clear();
      await tester.tap(find.text('下单并付款 ¥1.00'));
      await _settle(tester);
      expect(fake.paths.take(4), ['/goods/normal/details', '/goods/normal/skus', '/trade/preview/v4', '/trade/create']);
      expect(fake.paths, containsAllInOrder(['/payChannelRoute/againPay', '/pay/unify/prePay', '/order/detail']));
      expect(alipay.paid, hasLength(1));
      expect(find.byType(PangguaiOrderPage), findsOneWidget);
      expect(find.text('使用中'), findsOneWidget);
      expect(find.textContaining(RegExp(r'^预计 \d{2}:\d{2} 结束$')), findsOneWidget);
      expect(find.text('设备没启动？重新启动'), findsOneWidget);
      await tester.tap(find.text('设备没启动？重新启动'));
      await _settle(tester);
      expect(fake.count('/trade/order/start'), 1);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('吹风机：先选位置再选时长（不能选的时长灰掉），按分钟数下单', (tester) async {
      await signIn(tester);
      await open(tester, PangguaiDevicePage(service: service, phone: _phone, goodsId: '9002'));
      expect(find.text('选位置'), findsOneWidget);
      expect(find.text('选时长'), findsOneWidget);
      final unavailable = tester.widget<CampusGlassChip>(find.widgetWithText(CampusGlassChip, '7 分钟 · ¥1.20'));
      expect(unavailable.onSelected, isNull);
      expect(find.text('下单并付款 ¥0.66'), findsOneWidget, reason: '默认选第一个能选的时长（3 分钟）');
      await tester.tap(find.text('5 分钟 · ¥1.00'));
      await tester.pump();
      await tester.tap(find.text('下单并付款 ¥1.00'));
      await _settle(tester);
      expect(jsonDecode(fake.last('/trade/create')['items']!), [{'goodsId': '9002', 'skuId': '21', 'amount': '5', 'soldType': '1', 'num': '5'}]);
      expect(find.text('使用中'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('只有一个档位且不分时长：不用选，直接下单并付款', (tester) async {
      await signIn(tester);
      await open(tester, PangguaiDevicePage(service: service, phone: _phone, goodsId: '9003'));
      expect(find.text('选程序'), findsNothing);
      expect(find.byWidgetPredicate((widget) => _dotted(widget, '烘干 · 约 40 分钟')), findsOneWidget);
      expect(find.text('下单并付款 ¥2.50'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('先用后付的饮水机写明去官方 App；离线的设备写原因，都不给下单', (tester) async {
      await signIn(tester);
      await open(tester, PangguaiDevicePage(service: service, phone: _phone, goodsId: '9004'));
      expect(find.text('这台饮水机是先用后付，暂时只能在胖乖生活 App 里用'), findsOneWidget);
      expect(find.textContaining('下单并付款'), findsNothing);
      expect(fake.count('/goods/normal/skus'), 0);
      await tester.pumpWidget(const SizedBox());
      await open(tester, PangguaiDevicePage(service: service, phone: _phone, goodsId: '9005'));
      expect(find.text('设备离线了'), findsOneWidget);
      expect(find.textContaining('下单并付款'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('价变了：先停下写明新价，再点一次按新价下单', (tester) async {
      await signIn(tester);
      fake.previewExtra = 10;
      await open(tester, PangguaiDevicePage(service: service, phone: _phone, goodsId: '9001'));
      await tester.tap(find.text('下单并付款 ¥5.00'));
      await _settle(tester);
      expect(find.text('胖乖算出来要付 ¥5.10，确认后再点一次'), findsOneWidget);
      expect(fake.count('/trade/create'), 0);
      await tester.tap(find.text('下单并付款 ¥5.10'));
      await _settle(tester);
      expect(fake.count('/trade/create'), 1);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('在支付宝里取消：订单还是待付款、能再付；取消订单先确认，再从胖乖的订单里删掉', (tester) async {
      await signIn(tester);
      alipay.status = '6001';
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(navigatorKey: navigator, theme: campusTheme(), home: const Scaffold(body: Text('首页'))));
      unawaited(navigator.currentState!.push<void>(MaterialPageRoute(builder: (_) => PangguaiDevicePage(service: service, phone: _phone, goodsId: '9001'))));
      await _settle(tester);
      await tester.tap(find.text('下单并付款 ¥5.00'));
      await _settle(tester);
      expect(find.text('已取消付款'), findsOneWidget);
      expect(find.text('用支付宝付 ¥5.00'), findsOneWidget);
      expect(find.textContaining('内付款，过时订单失效'), findsOneWidget);
      await tester.tap(find.text('取消订单'));
      await _settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, '取消订单'));
      await _settle(tester);
      expect(fake.paths, containsAllInOrder(['/order/cancel', '/order/hidden']));
      expect(fake.orders, isEmpty);
      expect(find.text('首页'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('首页列出进行中的订单（待付款与使用中），点进去是订单页', (tester) async {
      await signIn(tester);
      await tester.runAsync(() async {
        final first = await service.place(_phone, goodsId: '9001', item: const PangguaiItem(goodsId: '9001', skuId: '13'), expected: 100) as PangguaiPlaced;
        fake.pay(first.order.orderId);
        await service.place(_phone, goodsId: '9001', item: const PangguaiItem(goodsId: '9001', skuId: '12'), expected: 400);
      });
      await open(tester, PangguaiPage(runtime: runtime()));
      expect(find.text('使用中'), findsOneWidget);
      expect(find.text('待付款 ¥4.00'), findsOneWidget);
      expect(find.byWidgetPredicate((widget) => widget is DotSeparatedText && widget.text.startsWith('合成楼-101 · 单脱 · 预计 ')), findsOneWidget);
      await tester.tap(find.text('待付款 ¥4.00'));
      await _settle(tester);
      expect(find.byType(PangguaiOrderPage), findsOneWidget);
      expect(find.text('用支付宝付 ¥4.00'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('扫码：胖乖的设备码直接换成设备页，饮水机码换成胖乖的网页，别的码原地提示', (tester) async {
      await signIn(tester);
      String? rejected;
      Widget Function(String raw)? builder;
      await open(
        tester,
        PangguaiPage(
          runtime: runtime(
            scan: (context, hint, accept, {then}) async {
              rejected = accept('https://example.com');
              builder = then;
              unawaited(Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => then!('https://h5.qiekj.com/skip?NQT=abcd-1234'))));
              return null;
            },
          ),
        ),
      );
      await tester.tap(find.text('扫码'));
      await _settle(tester);
      expect(rejected, '不是胖乖生活的设备码');
      expect(find.byType(PangguaiDevicePage), findsOneWidget);
      expect(fake.last('/goods/scan/v2'), containsPair('NQT', 'abcd-1234'));
      expect(find.text('合成楼-101'), findsOneWidget);
      expect(builder!('http://apwork.cn/scan/qie?ABCDEF0123456789'), isA<PangguaiWaterPage>().having((page) => page.token, 'token', startsWith('TOKEN-')));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('附近门店：取位置后列门店，点进去按机型列设备，点设备进设备页', (tester) async {
      await signIn(tester);
      await open(tester, PangguaiPage(runtime: runtime()));
      await tester.tap(find.text('附近门店'));
      await _settle(tester);
      expect(locator.asked.last, isTrue);
      expect(fake.last('/shop/nearby/list'), allOf(containsPair('latitude', '36.123456'), containsPair('longitude', '117.654321')));
      expect(find.byWidgetPredicate((widget) => _dotted(widget, '86 米 · 12 台 · 合成路 1 号')), findsOneWidget);
      await tester.tap(find.text('合成学院洗衣房'));
      await _settle(tester);
      expect(fake.last('/appointNew/near/newMachines'), allOf(containsPair('orgId', '0'), containsPair('shopId', 'S0001'), containsPair('machineTypeId', '00')));
      await tester.tap(find.text('吹风'));
      await _settle(tester);
      await tester.tap(find.text('合成楼3层吹风'));
      await _settle(tester);
      expect(find.text('选时长'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('附近门店：没有定位权限时原地写明并给「去设置」', (tester) async {
      await signIn(tester);
      locator.failure = PangguaiLocateFailure.denied;
      await open(tester, PangguaiPage(runtime: runtime()));
      await tester.tap(find.text('附近门店'));
      await _settle(tester);
      expect(find.text('没有定位权限'), findsOneWidget);
      await tester.tap(find.text('去设置'));
      await _settle(tester);
      expect(locator.opened, [PangguaiLocateFailure.denied]);
      expect(fake.count('/shop/nearby/list'), 0);
      await tester.pumpWidget(const SizedBox());
    });
  });

  test('注册表：胖乖生活登记在生活下面，碰真钱所以有自己的开关、默认关', () async {
    final fixture = ToolboxFixture();
    await fixture.initialize();
    addTearDown(fixture.close);
    final life = toolboxCatalog(fixture.runtime).singleWhere((module) => module.id == 'life');
    final module = life.children.singleWhere((child) => child.id == PangguaiService.serviceId);
    expect(module.flag, pangguaiFlag);
    expect(pangguaiFlag.fallback, isFalse);
    expect(featureFlags, contains(pangguaiFlag));
    expect(toolboxPath(module), '/toolbox/life/pangguai');
    expect(module.clearedData, isNotEmpty);
  });
}

http.Response _json(Map<String, Object?> body) => http.Response.bytes(utf8.encode(jsonEncode(body)), 200, headers: {'content-type': 'application/json'});
