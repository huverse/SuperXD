import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:superxd/toolbox/life/life_alipay.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/dot_separated_text.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_client.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_devices.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_http.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_models.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_page.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_protocol.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_recharge_page.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_service.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_vault.dart';
import 'package:superxd/toolbox/toolbox_catalog.dart';
import 'package:superxd/toolbox/toolbox_runtime.dart';

import 'toolbox_test_support.dart';

// 住理生活第三轮：充值与买券（用支付宝付，人工决策见 lib/toolbox/life/zhuli/zhuli_service.dart 文件头）。订单与支付串都是合成的。

const _phone = '13800000001', _password = '123456';
const _alipay = 'app_id=2021000000000000&method=alipay.trade.app.pay&biz_content=%7B%7D&sign=SYNTHETIC';

// 假住理：登录、账户、配置、额度、券商品、下单与到账查询；记下每次请求。paidAfter 是第几次查到账时才算到账（为空就一直没到账）。
class _FakePay {
  final requests = <Uri>[];
  final valid = <String>{};
  var counter = 0;
  Map<String, Object?> config = {'recharge_enable': 1, 'recharge_display_enable': 1, 'recharge_unenable_desc': '关闭充值', 'alipay_enable': 1, 'bath_enable': 0};
  int? paidAfter = 1;
  var checks = 0;
  var orderContent = _alipay;

  int count(String path) => requests.where((uri) => uri.path == path).length;
  Map<String, String> lastQuery(String path) => requests.lastWhere((uri) => uri.path == path).queryParameters;

  bool _paid() => paidAfter != null && ++checks >= paidAfter!;

  late final client = MockClient((request) async {
    requests.add(request.url);
    final query = request.url.queryParameters;
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
    } else if (!valid.contains(query['identitycode'])) {
      reply = fail('login_timeout');
    } else {
      reply = switch (request.url.path) {
        '/webapi/v1/staff/get_user_detail_by_id' => ok({'balance': checks > 0 && paidAfter != null && checks >= paidAfter! ? '37.4900' : '17.4900', 'frozen_balance': 0.0, 'cash_coupon_count': 1}),
        '/webapi/v1/app_setting/get_config' => ok(config),
        '/webapi/v1/consume/get_staff_last_record' => ok(null),
        '/webapi/v1/recharge/list_recharge_quota' => ok([
          for (final value in [20.0, 50.0]) {'quota': value, 'gift_value': 0.0, 'id': '00000000-0000-0000-0000-000000000000', 'cash_coupon_money': 0.0, 'cash_coupon_count': 0, 'uselimit': null},
          {'quota': 100.0, 'gift_value': 0.0, 'id': 'G1', 'cash_coupon_money': 10.0, 'cash_coupon_count': 2, 'uselimit': 'bath'},
        ]),
        '/webapi/v1/recharge/createorder' => ok({'order_id': 'AL1_9', 'recharge_id': 'R1', 'order_content': orderContent, 'create_at': '2026-11-22 22:00:00', 'out_trade_no': null}),
        '/webapi/v1/recharge/get_order_by_out_trade_no' => ok({'out_trade_no': query['out_trade_no'], 'recharge_value': 20.0, 'status': _paid() ? 0 : 7, 'create_at': '2026-11-22 22:00:00'}),
        '/webapi/v1/cash_coupon/get_cash_coupon_app' => ok([
          {'id': 'C1', 'name': '合成券', 'price': 100.0, 'money': 130.0, 'use_limit': 'bath', 'use_order': 0, 'total_count': 495, 'limit_count': 1, 'gained_count': 0, 'start_at': '2026-09-03 17:52:35', 'expire_at': '2028-09-30 23:59:59', 'validated_days': 0},
          {'id': 'C2', 'name': '限购券', 'price': 50.0, 'money': 60.0, 'use_limit': 'bath', 'use_order': 1, 'total_count': 3, 'limit_count': 1, 'gained_count': 1, 'expire_at': '2099-12-31 23:59:59', 'validated_days': 30},
          {'id': 'C3', 'name': '售罄券', 'price': 10.0, 'money': 12.0, 'use_limit': '', 'use_order': 0, 'total_count': 0, 'limit_count': 0, 'gained_count': 0, 'expire_at': '', 'validated_days': 0},
        ]),
        '/webapi/v1/cash_coupon/buy_cash_coupon' => ok({'order_id': '261122_9', 'order_content': orderContent}),
        '/webapi/v1/cash_coupon/list_staff_cash_coupon_app' when query.containsKey('id') => ok({'rows': _paid() ? [{'id': 'Q9', 'trade_status': 'TRADE_SUCCESS', 'balance': 130.0}] : <Object>[], 'total_count': 0}),
        '/webapi/v1/cash_coupon/list_staff_cash_coupon_app' => ok({'rows': <Object>[], 'total_count': 0}),
        _ => fail('not_found'),
      };
    }
    return http.Response(jsonEncode(reply), 200, headers: {'content-type': 'application/json; charset=utf-8'});
  });
}

// 假支付宝：记下交给它的支付串，回 status；never 时一直不回（iOS 上 SDK 的回调回不来）。
class _FakePayer implements LifeAlipay {
  _FakePayer(this.status);
  String? status;
  final orders = <String>[];
  // 没给 status 时这一单的回调，测试里手动完成（模拟回到前台比结果码先到）。
  var pending = Completer<String>();

  @override
  Future<String> pay(String orderContent) {
    orders.add(orderContent);
    final status = this.status;
    if (status != null) return Future.value(status);
    pending = Completer<String>();
    return pending.future;
  }
}

ZhuliService _service(_FakePay fake, _FakePayer payer) =>
    ZhuliService(vault: MemoryZhuliVault(), devices: ZhuliDeviceStore.memory(), client: ZhuliClient(http: ZhuliHttp(client: fake.client)), payer: payer);

Future<void> _settle(WidgetTester tester, {int rounds = 20}) async {
  for (var index = 0; index < rounds; index++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Map<String, Object?> _rechargeRecord(Map<String, String> query) => jsonDecode(utf8.decode(base64.decode(query['base64_rechargerecord']!.replaceAll('-', '+').replaceAll('_', '/')))) as Map<String, Object?>;

void main() {
  group('数据与请求', () {
    test('额度、券商品与付款单按外部输入解；只认支付宝 APP 支付串；配置里关了充值写原因', () {
      final quotas = decodeZhuliQuotas([{'quota': 20.0, 'cash_coupon_count': 0, 'cash_coupon_money': 0.0}, {'quota': '0.01', 'cash_coupon_count': 2, 'cash_coupon_money': 10.0}]);
      expect([for (final quota in quotas) (quota.value, quota.giftCount, quota.giftMoney)], [(2000, 0, 0), (1, 2, 1000)]);
      final goods = decodeZhuliGoods([{'id': 'C', 'price': 100.0, 'money': 130.0, 'total_count': 0, 'limit_count': 1, 'gained_count': 1, 'use_order': 1}]).single;
      expect((goods.price, goods.money, goods.couponFirst, goods.unavailable), (10000, 13000, false, '限购 1 张，已买满'));
      expect(decodeZhuliPayOrder({'order_id': 'O', 'order_content': _alipay}).orderId, 'O');
      expect(() => decodeZhuliPayOrder({'order_id': 'O', 'order_content': '{"appid":"wx","package":"Sign=WXPay"}'}), throwsA(isA<ZhuliException>().having((error) => error.failure, 'failure', ZhuliFailure.rejected)), reason: '微信付款串不接');
      expect([decodeZhuliCouponPaid({'rows': <Object>[]}), decodeZhuliCouponPaid({'rows': [{'trade_status': 'TRADE_SUCCESS'}]})], [false, true]);
      final closed = decodeZhuliConfig({'recharge_enable': 0, 'recharge_unenable_desc': '关闭充值', 'recharge_display_enable': 1, 'alipay_enable': 1});
      expect((closed.rechargeClosed, closed.rechargeShown, closed.alipay), ('关闭充值', true, true));
      expect(decodeZhuliConfig({}).alipay, isFalse, reason: '没说开就当没开支付宝');
    });

    test('自定义充值只收 0.01–500 元、最多两位小数（住理只拒负数，客户端限住）', () {
      expect([for (final text in ['0.01', '20', '19.99', '500', ' 3.5 ']) zhuliRechargeCents(text)], [1, 2000, 1999, 50000, 350]);
      expect([for (final text in ['0', '0.001', '500.01', '1000', '-1', '1.2.3', '', 'abc']) zhuliRechargeCents(text)], everyElement(isNull));
    });

    test('充值下单：base64 的 rechargerecord 里写金额、只走支付宝、充给自己；买券不带金额', () async {
      final fake = _FakePay();
      final service = _service(fake, _FakePayer('9000'));
      await service.signIn(_phone, _password);
      final order = await service.run(_phone, (session) => service.client.recharge(session, 1));
      expect((order.orderId, order.orderContent), ('AL1_9', _alipay));
      final record = _rechargeRecord(fake.lastQuery('/webapi/v1/recharge/createorder'));
      expect(record, {'user_id': 'U1', 'recharge_value': 0.01, 'staff_id': '', 'isminiprogram': 'False', 'trade_type': 'APP', 'recharge_method': 'alipay', 'use_platform': 'Android'});
      await service.run(_phone, (session) => service.client.buyCoupon(session, 'C1'));
      final buy = fake.lastQuery('/webapi/v1/cash_coupon/buy_cash_coupon');
      expect((buy['cash_coupon_id'], buy['pay_type'], buy['staff_id'], buy['user_id']), ('C1', 'alipay', '', 'U1'), reason: 'staff_id 空串是买给自己');
      expect(buy.keys.any((key) => key.contains('money') || key.contains('price') || key.contains('value')), isFalse);
    });
  });

  group('页面与结账', () {
    late _FakePay fake;

    Future<ZhuliService> signIn(WidgetTester tester, _FakePayer payer) async {
      final service = _service(fake, payer);
      await tester.runAsync(() => service.signIn(_phone, _password));
      return service;
    }

    setUp(() => fake = _FakePay());

    testWidgets('充值：点额度或输其他金额，用支付宝付；付完去住理查到账、刷新余额', (tester) async {
      final payer = _FakePayer('9000');
      final service = await signIn(tester, payer);
      fake.paidAfter = 2;
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ZhuliRechargePage(service: service, phone: _phone)));
      await _settle(tester);
      expect(find.text('¥17.49'), findsOneWidget);
      expect(find.text('¥20'), findsOneWidget);
      expect(find.text('用支付宝付 ¥20.00'), findsOneWidget, reason: '默认选第一档');
      await tester.tap(find.text('¥100'));
      await _settle(tester);
      expect(find.text('送 2 张 ¥10.00 的券'), findsOneWidget);
      await tester.tap(find.text('其他金额'));
      await _settle(tester);
      await tester.enterText(find.byType(TextField), '600');
      await tester.pump();
      expect(find.text('0.01 到 500.00 元，最多两位小数'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '0.01');
      await tester.pump();
      await tester.tap(find.text('用支付宝付 ¥0.01'));
      await _settle(tester, rounds: 40);
      expect(payer.orders, [_alipay]);
      expect(_rechargeRecord(fake.lastQuery('/webapi/v1/recharge/createorder'))['recharge_value'], 0.01);
      expect(find.text('付款成功'), findsOneWidget);
      expect(fake.count('/webapi/v1/recharge/get_order_by_out_trade_no'), 2, reason: '第二次查到才到账');
      expect(find.text('¥37.49'), findsOneWidget, reason: '到账后刷新余额');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('支付宝报取消：回到能再付的样子；一直查不到到账：写去哪看、可再查一次', (tester) async {
      final payer = _FakePayer('6001');
      final service = await signIn(tester, payer);
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ZhuliRechargePage(service: service, phone: _phone)));
      await _settle(tester);
      await tester.tap(find.text('用支付宝付 ¥20.00'));
      await _settle(tester);
      expect(find.text('已取消付款'), findsOneWidget);
      expect(fake.count('/webapi/v1/recharge/get_order_by_out_trade_no'), 0);
      payer.status = '9000';
      fake.paidAfter = null;
      await tester.tap(find.text('用支付宝付 ¥20.00'));
      await _settle(tester, rounds: 120);
      expect(fake.count('/webapi/v1/recharge/get_order_by_out_trade_no'), 10, reason: '1 秒一次、最多 10 次');
      expect(find.text('付款结果还在确认，稍后在订单的「充值」里看'), findsOneWidget);
      fake.paidAfter = fake.checks + 1;
      await tester.tap(find.text('再查一次'));
      await _settle(tester);
      expect(find.text('付款成功'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('回到前台比支付宝的结果码先到：查着时报取消，查一次没到账就回到能再付的样子；报失败同样', (tester) async {
      final payer = _FakePayer(null);
      final service = await signIn(tester, payer);
      fake.paidAfter = null;
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ZhuliRechargePage(service: service, phone: _phone)));
      await _settle(tester);
      for (final (status, message) in [('6001', '已取消付款'), ('4000', '付款没成功，可以再付一次')]) {
        final before = fake.count('/webapi/v1/recharge/get_order_by_out_trade_no');
        await tester.tap(find.text('用支付宝付 ¥20.00'));
        await _settle(tester, rounds: 5);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        payer.pending.complete(status);
        await _settle(tester, rounds: 30);
        expect(find.text(message), findsOneWidget, reason: status);
        expect(fake.count('/webapi/v1/recharge/get_order_by_out_trade_no') - before, lessThanOrEqualTo(2), reason: '不查满 10 次');
      }
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('支付宝 SDK 一直不回调（iOS 场景模式）：回到前台或点「我已付款」就去住理查', (tester) async {
      final payer = _FakePayer(null);
      final service = await signIn(tester, payer);
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ZhuliRechargePage(service: service, phone: _phone)));
      await _settle(tester);
      await tester.tap(find.text('用支付宝付 ¥20.00'));
      await _settle(tester);
      expect(find.text('在支付宝里付款，付完回到这里'), findsOneWidget);
      expect(fake.count('/webapi/v1/recharge/get_order_by_out_trade_no'), 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _settle(tester);
      expect(find.text('付款成功'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('买券：只写售价、面额、先用谁与限购，限购买满与售罄不给买；弹层里同样三项、没有使用规则，付款后按订单号查券到账', (tester) async {
      final payer = _FakePayer('9000');
      final service = await signIn(tester, payer);
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ZhuliShopPage(service: service, phone: _phone)));
      await _settle(tester);
      expect(find.text('¥100.00'), findsOneWidget);
      expect(find.byWidgetPredicate((widget) => widget is DotSeparatedText && widget.text == '面额 ¥130.00 · 优先用券 · 限购 1 张'), findsOneWidget);
      expect(find.byWidgetPredicate((widget) => widget is DotSeparatedText && widget.text == '面额 ¥60.00 · 优先用余额 · 限购 1 张'), findsOneWidget);
      expect(find.byWidgetPredicate((widget) => widget is DotSeparatedText && widget.text == '面额 ¥12.00 · 优先用券'), findsOneWidget, reason: '不限购不写');
      expect(tester.widget<FilledButton>(find.ancestor(of: find.text('限购 1 张，已买满'), matching: find.byWidgetPredicate((widget) => widget is FilledButton))).onPressed, isNull);
      expect(tester.widget<FilledButton>(find.ancestor(of: find.text('已售罄'), matching: find.byWidgetPredicate((widget) => widget is FilledButton))).onPressed, isNull);
      await tester.tap(find.text('购买'));
      await _settle(tester);
      expect(find.text('使用规则'), findsNothing);
      await tester.tap(find.text('用支付宝付 ¥100.00'));
      await _settle(tester, rounds: 30);
      expect(fake.lastQuery('/webapi/v1/cash_coupon/buy_cash_coupon')['cash_coupon_id'], 'C1');
      expect(fake.lastQuery('/webapi/v1/cash_coupon/list_staff_cash_coupon_app')['id'], '261122_9');
      expect(find.text('付款成功'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('首页：学校开着充值入口时余额卡下有「充值」「买券」；关着入口时没有；关了充值时充值页写原因', (tester) async {
      final fixture = ToolboxFixture();
      await tester.runAsync(fixture.initialize);
      addTearDown(fixture.close);
      final service = await signIn(tester, _FakePayer('9000'));
      await tester.runAsync(() => fixture.store.grantConsent(ZhuliService.serviceId, ZhuliService.consentVersion));
      final runtime = ToolboxRuntime.testing(catalog: toolboxCatalog, store: fixture.store, downloads: fixture.manager, services: {ZhuliService.serviceId: service});
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ZhuliPage(runtime: runtime)));
      await _settle(tester);
      expect(find.text('充值'), findsOneWidget);
      expect(find.text('买券'), findsOneWidget);
      fake.config = {...fake.config, 'recharge_enable': 0};
      await tester.tap(find.text('充值'));
      await _settle(tester);
      expect(find.text('关闭充值'), findsOneWidget);
      expect(find.text('用支付宝付 ¥20.00'), findsNothing);
      await tester.tap(find.byTooltip('返回'));
      await _settle(tester);
      fake.config = {...fake.config, 'recharge_display_enable': 0};
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ZhuliPage(runtime: runtime)));
      await _settle(tester);
      expect(find.text('充值'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
