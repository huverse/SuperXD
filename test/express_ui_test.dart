import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/toolbox/express/express_client.dart';
import 'package:superxd/toolbox/express/express_controller.dart';
import 'package:superxd/toolbox/express/express_http.dart';
import 'package:superxd/toolbox/express/express_models.dart';
import 'package:superxd/toolbox/express/express_page.dart';
import 'package:superxd/toolbox/express/express_service.dart';
import 'package:superxd/toolbox/express/express_vault.dart';
import 'package:superxd/toolbox/toolbox_catalog.dart';
import 'package:superxd/toolbox/toolbox_runtime.dart';

import 'toolbox_test_support.dart';

const _session = PddSession(accessToken: 'tok', cookie: 'PDDAccessToken=tok', userId: '7209');

// 合成拼多多服务：按路径回合成数据，身份码固定一串 dd 码。
http.Client _fakeClient() => MockClient((request) async {
  final path = request.url.path;
  Map<String, Object?> body;
  if (path.endsWith('express/detail')) {
    body = {'success': true, 'error_code': '0', 'new_binding_list': [{'mobile_id': 'm1', 'mock_mobile': '138****8888', 'alias': '自己'}]};
  } else if (path.endsWith('station/package')) {
    body = {'success': true, 'error_code': '0', 'result': {'count': 0, 'no_package_mobile_info': {'mobileList': ['8888']}}};
  } else {
    body = {'success': true, 'error_code': '0', 'result': {'identification_code': 'dd202610190000000000001', 'expire_mills': 132000, 'mobile_info': {'mobile_info_desc': '已绑定常用手机号：138****8888'}}};
  }
  return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json;charset=UTF-8'});
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ToolboxFixture fixture;
  late MemoryExpressVault vault;

  ToolboxRuntime buildRuntime() => ToolboxRuntime.testing(
    catalog: toolboxCatalog,
    store: fixture.store,
    downloads: fixture.manager,
    services: {
      ExpressService.serviceId: ExpressService(
        vault: vault,
        clientFactory: (session) => ExpressClient(session: session, http: ExpressHttp(client: _fakeClient())),
      ),
    },
  );

  setUp(() async {
    fixture = ToolboxFixture();
    await fixture.initialize();
    vault = MemoryExpressVault();
  });

  tearDown(() async => fixture.close());

  testWidgets('未登录显示登录入口', (tester) async {
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ExpressPage(runtime: buildRuntime())));
    await tester.pumpAndSettle();
    expect(find.text('登录拼多多'), findsOneWidget);
    expect(find.text('已登录拼多多'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('已登录可查绑定手机号与驿站待取件', (tester) async {
    await vault.save(_session);
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ExpressPage(runtime: buildRuntime())));
    await tester.pumpAndSettle();
    expect(find.text('已登录拼多多'), findsOneWidget);

    await tester.tap(find.text('绑定手机号'));
    await tester.pumpAndSettle();
    expect(find.textContaining('138****8888'), findsOneWidget);

    await tester.tap(find.text('驿站快递'));
    await tester.pumpAndSettle();
    expect(find.textContaining('驿站待取件 0 件'), findsOneWidget);
    expect(find.textContaining('8888'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('生成身份码显示码值与勿分享提示', (tester) async {
    await vault.save(_session);
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ExpressPage(runtime: buildRuntime())));
    await tester.pumpAndSettle();

    await tester.tap(find.text('身份码'));
    // 身份码视图带 1 秒周期倒计时，不能 pumpAndSettle；用定长 pump 让请求完成。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('dd202610190000000000001'), findsOneWidget);
    expect(find.textContaining('请勿随意分享身份码'), findsOneWidget);
    // 销毁页面取消倒计时定时器，避免 pending timer 报错。
    await tester.pumpWidget(const SizedBox());
  });

  test('清除数据删除登录会话', () async {
    await vault.save(_session);
    final service = ExpressService(vault: vault);
    await service.clearData();
    expect(await vault.load(), isNull);
  });

  test('拿到未登录会回到登录态并清掉会话', () async {
    await vault.save(const PddSession(accessToken: 'stale'));
    final service = ExpressService(
      vault: vault,
      clientFactory: (session) => ExpressClient(
        session: session,
        http: ExpressHttp(client: MockClient((request) async => http.Response(jsonEncode({'error_code': 40001}), 200, headers: {'content-type': 'application/json'}))),
      ),
    );
    final controller = ExpressController(service);
    await controller.initialize();
    expect(controller.loggedIn, isTrue);
    await controller.generateIdentityCode();
    expect(controller.loggedIn, isFalse);
    expect(await vault.load(), isNull);
    controller.dispose();
  });
}
