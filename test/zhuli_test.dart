import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:superxd/domain/feature_flags.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/dot_separated_text.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_client.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_coupons_page.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_devices.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_http.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_models.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_orders_page.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_page.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_protocol.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_service.dart';
import 'package:superxd/toolbox/life/zhuli/zhuli_vault.dart';
import 'package:superxd/toolbox/toolbox_catalog.dart';
import 'package:superxd/toolbox/toolbox_page.dart';
import 'package:superxd/toolbox/toolbox_runtime.dart';

import 'toolbox_test_support.dart';

// 住理生活第一轮（人工决策见 lib/toolbox/life/zhuli/zhuli_service.dart 文件头）：协议、数据、会话与页面。数据全是合成的。

const _phone = '13800000001', _other = '13800000002', _password = '123456';

// 内存里的假住理：按路径回合成数据，data 照真实服务端写成 base64；记下每次请求的路径与参数。
class _FakeZhuli {
  final requests = <Uri>[];
  final passwords = {_phone: _password, _other: '654321'};
  var sessionCounter = 0;
  // 当前有效的身份码（换了就让旧的回 login_timeout）。
  final valid = <String>{};
  var captchaNext = false;
  String? captchaExpected;
  var balance = '17.4900';
  // 新的在前、每条隔 7 小时（同真实服务端的先后）。
  final consume = [
    for (var index = 0; index < 25; index++)
      {'order_id': 'C$index', 'consume_type': 'bath', 'status': 'finished', 'create_at': zhuliClock(DateTime.utc(2026, 11, 20).subtract(Duration(hours: 7 * index))), 'consume_money': 0.14, 'device_settle_type': 2, 'pay_trade_status': 'TRADE_SUCCESS', 'device_name': '合成房间'},
  ];
  final recharge = [for (var index = 0; index < 23; index++) {'out_trade_no': 'R$index', 'status': index.isEven ? 0 : 12, 'recharge_value': 20.0, 'create_at': '2026-11-01 10:00:00'}];

  late final client = MockClient((request) async {
    requests.add(request.url);
    final query = request.url.queryParameters;
    Map<String, Object?> ok(Object? data) => {'result': true, 'data': zhuliBase64(jsonEncode(data)), 'msg': null};
    Map<String, Object?> fail(String? code, [String? message]) => {'result': false, 'err_msg': code, 'msg': message, 'data': {}};
    Map<String, Object?> reply;
    if (request.url.host == 'pm.whxinna.com') {
      reply = switch (request.url.path) {
        '/webapi/users/login' => _login(query),
        '/webapi/users/get_login_code' => ok({'codeImg': '<svg xmlns="http://www.w3.org/2000/svg" width="150" height="50"><path d="M0 0L10 10"/></svg>'}),
        '/webapi/users/sendresetpwdSMS' => ok({}),
        '/webapi/users/resetpwd' => query['code'] == '2468' ? ok({}) : fail(null, '验证码错误'),
        _ => fail('not_found'),
      };
    } else if (!valid.contains(query['identitycode'])) {
      reply = fail('login_timeout');
    } else {
      reply = switch (request.url.path) {
        '/webapi/v1/staff/get_user_detail_by_id' => ok({'id': 'U1', 'balance': balance, 'frozen_balance': 0.0, 'total_balance': 17.49, 'cash_coupon_count': 1}),
        '/webapi/v1/app_setting/get_config' => ok({'consume_order_display_cut_enable': 1, 'consume_order_display_cut_days': 30}),
        '/webapi/v1/consume/get_staff_last_record' => ok(null),
        '/webapi/v1/cash_coupon/list_staff_cash_coupon_app' => ok(query['is_blance'] == '1'
            ? {'rows': [{'id': 'Q1', 'cash_coupon_name': '合成券', 'balance': 176.35, 'total_money': 280.0, 'use_limit': 'bath', 'use_order': 0, 'start_at': '2026-09-30 11:37:49', 'expire_at': '2028-09-19 11:37:49', 'status': null, 'is_blance': null}], 'total_count': 1}
            : {'rows': <Object>[], 'total_count': 0}),
        '/webapi/v1/cash_coupon/list_staff_cash_coupon_record' => ok({'rows': [{'coupon_balance': 176.35, 'create_at': '2026-11-22 13:39:58', 'value': -0.14, 'consume_record_id': 'C0', 'consume_type': 'bath'}], 'total_count': 1}),
        '/webapi/v1/consume/list_record_by_staffid' => ok(consume.where((record) => (record['create_at']! as String).compareTo(query['end']!) < 0).take(20).toList()),
        '/webapi/v1/staff/get_bill_detail_by_id' => ok({'order_id': query['bill_id'], 'consume_type': 'bath', 'status': 'finished', 'create_at': '2026-11-22 13:39:57', 'consume_money': 0.14, 'charge_money': 5.0, 'refund_money': 4.86, 'water_volume_1': 2.34, 'consume_timing': 21, 'device_name': '合成房间', 'building_name': '1号楼', 'floor_name': '2', 'room_name': '201', 'pay_channel': 0, 'deduct_from_coupon': 0.14, 'deduct_from_balance': 0.0, 'deduct_from_pay': 0.0}),
        '/webapi/v1/recharge/list_order_app' => ok({'rows': recharge.skip((int.parse(query['page_index']!) - 1) * 20).take(20).toList()}),
        '/webapi/v1/recharge/get_order_by_out_trade_no' => ok({'out_trade_no': query['out_trade_no'], 'recharge_value': 20.0, 'status': 0, 'trade_status': 'TRADE_SUCCESS', 'trade_no': 'T1', 'pay_time': '2026-11-01 10:01:00', 'create_at': '2026-11-01 10:00:00', 'recharge_type': 2, 'balance': 37.49}),
        _ => fail('not_found'),
      };
    }
    return http.Response(jsonEncode(reply), 200, headers: {'content-type': 'application/json; charset=utf-8'});
  });

  Map<String, Object?> _login(Map<String, String> query) {
    Map<String, Object?> fail(String message) => {'result': false, 'err_msg': null, 'msg': message, 'data': {}};
    if (captchaNext && query['code'] != captchaExpected) return fail(query['code'] == null || query['code']!.isEmpty ? '本次登录需要进行验证' : '验证码输入错误');
    if (passwords[query['phone']] != query['pwd']) return fail('密码错误，请重新输入');
    final identity = 'ID${++sessionCounter}';
    valid.add(identity);
    return {
      'result': true,
      'data': zhuliBase64(jsonEncode({
        'platform_token': 'P',
        'user_info': {'id': 'U1', 'phone': query['phone'], 'identity_code': identity, 'isbind': 1, 'balance': '0.0000'},
        'server_info': {'server_addr': 'https://zhuli999.whxinna.com', 'server_appid': 1, 'server_id': 2, 'appsecret': 'A', 'session_secret': 'S$sessionCounter', 'projectname': '合成学院'},
      })),
    };
  }

  // 让现有的会话全部过期（下一次业务请求回 login_timeout）。
  void expireAll() => valid.clear();

  int count(String path) => requests.where((uri) => uri.path == path).length;
}

ZhuliService _service(_FakeZhuli fake, {ZhuliVault? vault}) => ZhuliService(vault: vault ?? MemoryZhuliVault(), devices: ZhuliDeviceStore.memory(), client: ZhuliClient(http: ZhuliHttp(client: fake.client)));

void main() {
  group('协议', () {
    test('签名与原 App 一致（向量来自 11-22 被真实服务端接受的实现）：去空值、按键排序、值按 JSON.stringify、去引号与空格', () {
      final params = <String, Object?>{
        'id': 'u-1', 'page_index': 0, 'flag': true, 'off': false, 'value': 1.0, 'price': 0.07, 'name': '中文 名"引号', 'empty': '', 'none': null,
        'timestamp': '1795326373', 'noncestr': 'ypOz2MOkVirpODHDEyUPVlROMQALkxFd', 'base64_user_extends': zhuliBase64(jsonEncode({'isAlipayAppExist': false})),
      };
      expect(params['base64_user_extends'], 'eyJpc0FsaXBheUFwcEV4aXN0IjpmYWxzZX0=');
      expect(zhuliSign(params, 'k123'), '14AD0F4A6049B6B5B5D4301A373E0048');
      expect(zhuliBase64(jsonEncode([1, 3, 5, 6, 16, 32, 64, 80])), 'WzEsMyw1LDYsMTYsMzIsNjQsODBd');
      expect([zhuliJsValue(1.0), zhuliJsValue(0.07), zhuliJsValue(true), zhuliJsValue('a"b')], ['1', '0.07', 'true', r'"a\"b"']);
    });

    test('查询参数：对象换成 base64_<名>，带时刻、随机串与公共参数，签名覆盖公共参数；回复的 data 解开 base64', () {
      final query = zhuliQuery({'id': 'U1', 'user_extends': {'isAlipayAppExist': false}, 'flag': true}, key: 'K', common: {'user_id': 'U1', 'pid': 1}, now: DateTime.utc(2026, 11, 22), nonce: 'N');
      expect(query.containsKey('user_extends'), isFalse);
      expect(query['base64_user_extends'], 'eyJpc0FsaXBheUFwcEV4aXN0IjpmYWxzZX0=');
      expect((query['timestamp'], query['noncestr'], query['pid'], query['flag']), ('1795305600', 'N', '1', 'true'));
      final unsigned = {...query}..remove('sign');
      expect(query['sign'], zhuliSign(unsigned, 'K'));
      expect(zhuliDecodeData(zhuliBase64(jsonEncode({'a': '中文'}))), {'a': '中文'});
      expect(zhuliDecodeData({'b': 1}), {'b': 1});
      expect(zhuliNonce(), matches(RegExp(r'^[A-Za-z0-9]{32}$')));
    });

    test('消费订单号里取设备号（时间 14 位 + 设备 10 位 + 序号 8 位），别的格式不认', () {
      expect(zhuliOrderDevice('20261121165104000123456700002063'), 1234567);
      expect(zhuliOrderDevice('20261121165104000000432100000001'), 4321);
      expect([zhuliOrderDevice('C1'), zhuliOrderDevice('AL1_9'), zhuliOrderDevice('20261121165104000000000000000001')], everyElement(isNull));
    });

    test('金额按十进制文本换成分、四舍五入到分，不经浮点运算；时间按北京时间换成 UTC，占位的 0001 年当没有', () {
      expect([zhuliCents('13.3900'), zhuliCents(176.35), zhuliCents(-0.14), zhuliCents(0.005), zhuliCents(20), zhuliCents('x'), zhuliCents(null)], [1339, 17635, -14, 1, 2000, null, null]);
      expect([zhuliYuan(1840), zhuliYuan(-14), zhuliYuan(5)], ['18.40', '-0.14', '0.05']);
      expect(zhuliMoment('2026-11-22 13:39:57'), '2026-11-22T05:39:57.000Z');
      expect(zhuliMoment('0001-01-01 00:00:00'), isNull);
      expect(zhuliClock(DateTime.utc(2026, 11, 21, 16, 0, 5)), '2026-11-22 00:00:05');
    });

    test('登录回复是外部输入：业务地址只认 https 的 whxinna.com 主机，session_secret 盖过 appsecret', () {
      Map<String, Object?> login(String address, {String secret = 'S'}) => {
        'user_info': {'id': 'U', 'identity_code': 'I'},
        'server_info': {'server_addr': address, 'server_appid': 1, 'server_id': 2, 'appsecret': 'A', 'session_secret': secret, 'projectname': '合成学院'},
      };
      final session = decodeZhuliLogin(login('https://zhuli999.whxinna.com/'));
      expect((session.base.toString(), session.key, session.project, session.common['identitycode']), ('https://zhuli999.whxinna.com', 'S', '合成学院', 'I'));
      expect(decodeZhuliLogin(login('https://zhuli999.whxinna.com', secret: '')).key, 'A');
      for (final bad in ['http://zhuli999.whxinna.com', 'https://evil.example.com', 'https://whxinna.com.evil.com', 'https://zhuli999.whxinna.com:8443', 'https://u@zhuli999.whxinna.com']) {
        expect(() => decodeZhuliLogin(login(bad)), throwsA(isA<ZhuliException>().having((error) => error.failure, 'failure', ZhuliFailure.invalidResponse)), reason: bad);
      }
    });

    test('错误：login_timeout 是会话过期，三种图形验证码文案要验证码，中文文案原样给人看，非 JSON 与非 200 各有归类', () async {
      Future<ZhuliException> call(Object body, {int status = 200}) async {
        final transport = ZhuliHttp(client: MockClient((_) async => _reply(body, status)));
        try {
          await transport.get(Uri.parse('https://zhuli999.whxinna.com'), '/x', {}, key: 'K');
        } on ZhuliException catch (error) {
          return error;
        }
        fail('没有抛错');
      }

      expect((await call({'result': false, 'err_msg': 'login_timeout'})).failure, ZhuliFailure.sessionExpired);
      expect((await call({'result': false, 'msg': '本次登录需要进行验证'})).failure, ZhuliFailure.captchaRequired);
      expect((await call({'result': false, 'err_msg': 'CAPTCHA_REQUIRED'})).failure, ZhuliFailure.captchaRequired);
      final wrong = await call({'result': false, 'msg': '验证码输入错误'});
      expect((wrong.failure, wrong.message), (ZhuliFailure.captchaRequired, '验证码不对，换一张再输'));
      final rejected = await call({'result': false, 'msg': '密码错误，请重新输入'});
      expect((rejected.failure, rejected.message), (ZhuliFailure.rejected, '密码错误，请重新输入'));
      expect((await call({'result': false, 'err_msg': 'api_sign_error'})).message, '请求校验没通过，稍后再试');
      expect((await call('不是 JSON')).failure, ZhuliFailure.invalidResponse);
      expect((await call({'result': true}, status: 502)).failure, ZhuliFailure.network);
      // data 不是 base64 时照原 App 原样交回，格式对不对由各接口的 decode* 判断。
      final raw = await ZhuliHttp(client: MockClient((_) async => _reply({'result': true, 'data': 'not base64 json!'}, 200))).get(Uri.parse('https://zhuli999.whxinna.com'), '/x', {}, key: 'K');
      expect(raw, 'not base64 json!');
      expect(() => decodeZhuliProfile(raw), throwsA(isA<ZhuliException>().having((error) => error.failure, 'failure', ZhuliFailure.invalidResponse)));
    });
  });

  group('会话', () {
    test('登录成功才记密码并设为当前账号；会话过期自动重登一次再重放；同时几处过期只重登一次', () async {
      final fake = _FakeZhuli();
      final vault = MemoryZhuliVault();
      final service = _service(fake, vault: vault);
      await expectLater(service.signIn(_phone, '000000'), throwsA(isA<ZhuliException>().having((error) => error.message, 'message', '密码错误，请重新输入')));
      expect((await vault.load()).accounts, isEmpty);
      await service.signIn(_phone, _password);
      final state = await vault.load();
      expect((state.active, state.accounts.single.phone, state.device.isNotEmpty), (_phone, _phone, true));
      expect((await service.run(_phone, service.client.profile)).balance, 1749);

      fake.expireAll();
      final logins = fake.count('/webapi/users/login');
      final results = await Future.wait([service.run(_phone, service.client.profile), service.run(_phone, service.client.config)]);
      expect(((results[0] as ZhuliProfile).balance, (results[1] as ZhuliConfig).consumeOrderDays), (1749, 30));
      expect(fake.count('/webapi/users/login'), logins + 1, reason: '几处一起等同一次重登');

      // 换个服务实例（应用重开）：会话只在内存，第一次请求先用记着的密码登录。
      final reopened = _service(fake, vault: vault);
      expect((await reopened.run(_phone, reopened.client.profile)).balance, 1749);
      expect(fake.count('/webapi/users/login'), logins + 2);
    });

    test('后台重登时密码不对了归「请重新登录」，要图形验证码照原样交给页面；退出账号删掉密码、当前账号换成剩下的；最多记 10 个', () async {
      final fake = _FakeZhuli();
      final vault = MemoryZhuliVault();
      final service = _service(fake, vault: vault);
      await service.signIn(_phone, _password);
      await service.signIn(_other, '654321');
      expect((await vault.load()).active, _other);
      await service.switchTo(_phone);
      expect((await vault.load()).current!.phone, _phone);

      fake.passwords[_phone] = '111111';
      fake.expireAll();
      await expectLater(service.run(_phone, service.client.profile), throwsA(isA<ZhuliException>().having((error) => (error.failure, error.message), 'failure', (ZhuliFailure.notSignedIn, '密码错误，请重新输入'))));
      fake.captchaNext = true;
      await expectLater(service.run(_other, service.client.profile), throwsA(isA<ZhuliException>().having((error) => error.failure, 'failure', ZhuliFailure.captchaRequired)));

      await service.signOut(_phone);
      final state = await vault.load();
      expect(state.accounts.map((account) => account.phone), [_other]);
      expect(state.active, _other);

      final many = MemoryZhuliVault();
      final crowded = _service(fake..captchaNext = false, vault: many);
      for (var index = 0; index < 12; index++) {
        final phone = '139000000${index.toString().padLeft(2, '0')}';
        fake.passwords[phone] = _password;
        await crowded.signIn(phone, _password);
      }
      expect((await many.load()).accounts, hasLength(zhuliAccountLimit));
      await crowded.clearData();
      expect((await many.load()).accounts, isEmpty);
    });

    test('安全存储里的内容是外部输入：坏了整份当没有，坏的项跳过；设备串是随机的', () {
      expect(decodeZhuliVault('不是 JSON').accounts, isEmpty);
      final state = decodeZhuliVault(jsonEncode({'device': 'D', 'active': _phone, 'accounts': [{'phone': _phone, 'password': _password}, {'phone': 1}]}));
      expect((state.device, state.accounts.length, state.current!.phone), ('D', 1, _phone));
      expect(decodeZhuliVault(null).device, isNot(decodeZhuliVault(null).device));
    });

    test('券余额把未使用的券加起来（只读服务端给的余额，不推算抵扣）', () async {
      final fake = _FakeZhuli();
      final service = _service(fake);
      final session = await service.signIn(_phone, _password);
      expect(await service.couponBalance(session), (balance: 17635, count: 1));
      expect(fake.requests.last.queryParameters, containsPair('is_blance', '1'));
    });
  });

  group('页面', () {
    late ToolboxFixture fixture;
    late _FakeZhuli fake;
    late ZhuliService service;

    Future<void> open(WidgetTester tester) async {
      final runtime = ToolboxRuntime.testing(catalog: toolboxCatalog, store: fixture.store, downloads: fixture.manager, services: {ZhuliService.serviceId: service});
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ZhuliPage(runtime: runtime)));
      await _settle(tester);
    }

    setUp(() async {
      fixture = ToolboxFixture();
      await fixture.initialize();
      fake = _FakeZhuli();
      service = _service(fake);
    });
    tearDown(() => fixture.close());

    testWidgets('没登录时是登录表单：先取同意，登录后显示余额与券余额（服务端给的数）', (tester) async {
      await open(tester);
      expect(find.text('住理生活手机号'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, '住理生活手机号'), _phone);
      await tester.enterText(find.widgetWithText(TextField, '密码（6 位数字）'), _password);
      await tester.tap(find.text('登录'));
      await _settle(tester);
      expect(find.text('使用住理生活'), findsOneWidget);
      await tester.tap(find.text('同意并登录'));
      await _settle(tester);
      expect(find.text('¥17.49'), findsOneWidget);
      expect(find.text('¥176.35'), findsOneWidget);
      expect(find.text('1 张可用'), findsOneWidget);
      expect(find.text('合成学院'), findsOneWidget);
      expect(find.text('138****0001'), findsOneWidget);
      expect(await tester.runAsync(() => fixture.store.consent(ZhuliService.serviceId, ZhuliService.consentVersion)), isTrue);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('住理要图形验证码时原地出验证码，输对了才登进去；输错写明再换一张', (tester) async {
      await tester.runAsync(() => fixture.store.grantConsent(ZhuliService.serviceId, ZhuliService.consentVersion));
      fake
        ..captchaNext = true
        ..captchaExpected = 'AB12';
      await open(tester);
      await tester.enterText(find.widgetWithText(TextField, '住理生活手机号'), _phone);
      await tester.enterText(find.widgetWithText(TextField, '密码（6 位数字）'), _password);
      await tester.tap(find.text('登录'));
      await _settle(tester);
      expect(find.text('请输入图形验证码'), findsOneWidget);
      expect(find.byType(SvgPicture), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, '图形验证码'), 'ZZZZ');
      await tester.tap(find.text('登录'));
      await _settle(tester);
      expect(find.text('验证码不对，换一张再输'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, '图形验证码'), 'AB12');
      await tester.tap(find.text('登录'));
      await _settle(tester);
      expect(find.text('¥17.49'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('记着的密码在别处改过：首页原地请用户重新登录这个账号，手机号不能改', (tester) async {
      await tester.runAsync(() => service.signIn(_phone, _password));
      fake.passwords[_phone] = '222222';
      fake.expireAll();
      await open(tester);
      expect(find.text('密码错误，请重新输入'), findsOneWidget);
      final phoneField = tester.widget<TextField>(find.widgetWithText(TextField, '住理生活手机号'));
      expect((phoneField.controller!.text, phoneField.enabled), (_phone, false));
      await tester.runAsync(() => fixture.store.grantConsent(ZhuliService.serviceId, ZhuliService.consentVersion));
      await tester.enterText(find.widgetWithText(TextField, '密码（6 位数字）'), '222222');
      await tester.tap(find.text('登录'));
      await _settle(tester);
      expect(find.text('¥17.49'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('账号菜单：切换到另一个账号、退出这个账号（先确认，只删本机的密码）', (tester) async {
      await tester.runAsync(() async {
        await service.signIn(_other, '654321');
        await service.signIn(_phone, _password);
      });
      await open(tester);
      expect(find.text('138****0001'), findsOneWidget);
      await tester.tap(find.byTooltip('账号'));
      await _settle(tester);
      await tester.tap(find.text('切换到 138****0002'));
      await _settle(tester);
      expect(find.text('138****0002'), findsOneWidget);
      await tester.tap(find.byTooltip('账号'));
      await _settle(tester);
      await tester.tap(find.text('退出这个账号'));
      await _settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, '退出'));
      await _settle(tester);
      expect(find.text('138****0001'), findsOneWidget);
      expect((await tester.runAsync(service.state))!.accounts.map((account) => account.phone), [_phone]);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('优惠券：三栏、券上写余额面额适用与先后，点开按月看抵扣记录', (tester) async {
      await tester.runAsync(() => service.signIn(_phone, _password));
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ZhuliCouponsPage(service: service, phone: _phone)));
      await _settle(tester);
      expect(find.text('合成券'), findsOneWidget);
      // 说明行按「 · 」分项排（DotSeparatedText），按整句找。
      expect(find.byWidgetPredicate((widget) => widget is DotSeparatedText && widget.text == '面额 ¥280.00 · 适用洗浴 · 优先用券'), findsOneWidget);
      await tester.tap(find.text('合成券'));
      await _settle(tester);
      expect(find.text('合成券的抵扣记录'), findsOneWidget);
      expect(find.text('-0.14'), findsOneWidget);
      expect(find.text('余 176.35'), findsOneWidget);
      expect(fake.requests.last.queryParameters['date'], matches(RegExp(r'^\d{4}-\d{2}$')));
      await tester.tapAt(const Offset(10, 10));
      await _settle(tester);
      await tester.tap(find.text('已用完'));
      await _settle(tester);
      expect(find.text('没有已用完的券'), findsOneWidget);
      expect(fake.requests.last.queryParameters, containsPair('is_blance', '2'));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('订单：消费单按项目配置的天数查、用上一页最后一条的时刻翻页；充值单按页翻到底；点一条看详情', (tester) async {
      await tester.runAsync(() => service.signIn(_phone, _password));
      await tester.binding.setSurfaceSize(const Size(400, 3000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ZhuliOrdersPage(service: service, phone: _phone)));
      await _settle(tester);
      expect(find.text('洗浴 · 合成房间'), findsNWidgets(20));
      final first = fake.requests.lastWhere((uri) => uri.path == '/webapi/v1/consume/list_record_by_staffid').queryParameters;
      final start = DateTime.parse('${first['start']!.replaceFirst(' ', 'T')}+08:00'), end = DateTime.parse('${first['end']!.replaceFirst(' ', 'T')}+08:00');
      expect(end.difference(start).inDays, 30);
      await tester.tap(find.text('加载更多'));
      await _settle(tester);
      expect(find.text('洗浴 · 合成房间'), findsNWidgets(25));
      expect(find.text('加载更多'), findsNothing);
      expect(fake.requests.lastWhere((uri) => uri.path == '/webapi/v1/consume/list_record_by_staffid').queryParameters['end'], fake.consume[19]['create_at']);

      await tester.tap(find.text('洗浴 · 合成房间').first);
      await _settle(tester);
      expect(find.text('消费详情'), findsOneWidget);
      expect(find.text('2.34 升 · 21 秒'), findsOneWidget);
      expect(find.text('¥5.00'), findsOneWidget);
      expect(find.text('券 ¥0.14'), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await _settle(tester);

      await tester.tap(find.text('充值'));
      await _settle(tester);
      expect(find.text('充值'), findsNWidgets(21));
      await tester.tap(find.text('加载更多'));
      await _settle(tester);
      expect(find.text('加载更多'), findsNothing);
      expect(fake.requests.where((uri) => uri.path == '/webapi/v1/recharge/list_order_app').map((uri) => uri.queryParameters['page_index']), ['1', '2']);
      await tester.tap(find.textContaining('已到账').first);
      await _settle(tester);
      expect(find.text('充值详情'), findsOneWidget);
      expect(find.text('支付宝'), findsOneWidget);
      expect(find.text('¥37.49'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('找回密码：发短信验证码后倒数，两次新密码一致且 6 位数字才提交，重设成功回到登录表单', (tester) async {
      await open(tester);
      await tester.enterText(find.widgetWithText(TextField, '住理生活手机号'), _phone);
      await tester.tap(find.text('忘记密码'));
      await _settle(tester);
      expect(find.text('找回密码'), findsOneWidget);
      await tester.tap(find.text('获取验证码'));
      await _settle(tester);
      expect(find.textContaining('秒后重发'), findsOneWidget);
      expect(fake.requests.last.queryParameters['phone'], _phone);
      await tester.enterText(find.widgetWithText(TextField, '短信验证码'), '2468');
      await tester.enterText(find.widgetWithText(TextField, '新密码（6 位数字）'), '135790');
      await tester.enterText(find.widgetWithText(TextField, '再输一次新密码'), '135791');
      await tester.tap(find.text('重设密码'));
      await _settle(tester);
      expect(find.text('两次输入的新密码不一样'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, '再输一次新密码'), '135790');
      await tester.tap(find.text('重设密码'));
      await _settle(tester);
      expect(find.text('密码已重设，用新密码登录'), findsOneWidget);
      expect(fake.requests.last.queryParameters['newpwd'], '135790');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 61));
    });

    test('生活登记了住理生活：两层开关都开着才显示，id 与路由是 life.zhuli 与 /toolbox/life/zhuli', () {
      final life = toolboxCatalog(fixture.runtime).singleWhere((module) => module.id == 'life');
      final zhuli = life.children.single;
      expect((zhuli.id, zhuli.flag, zhuli.clearedData.isNotEmpty), (ZhuliService.serviceId, zhuliFlag, true));
      expect((zhuliFlag.id, zhuliFlag.fallback), ('toolbox.life.zhuli', false));
      expect(toolboxVisible(life, features: _Gate({lifeFlag.id})), isFalse);
      expect(toolboxVisible(life, features: _Gate({lifeFlag.id, zhuliFlag.id})), isTrue);
      expect(toolboxRedirect([life], '/toolbox/life/zhuli', features: _Gate({lifeFlag.id})), '/toolbox');
      expect(toolboxRedirect([life], '/toolbox/life/zhuli', features: _Gate({lifeFlag.id, zhuliFlag.id})), isNull);
    });
  });
}

http.Response _reply(Object body, int status) => http.Response(body is String ? body : jsonEncode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});

// 让假服务端（真实异步）与界面都走完：按真实时间等一小会儿再推一帧，最多约 2 秒。
Future<void> _settle(WidgetTester tester) async {
  for (var index = 0; index < 20; index++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

class _Gate implements FeatureGate {
  _Gate(this.on);
  final Set<String> on;
  @override
  bool isOn(FeatureFlag flag) => on.contains(flag.id);
  @override
  Stream<void> get changes => const Stream.empty();
}
