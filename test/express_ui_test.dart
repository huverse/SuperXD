import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:barcode_widget/barcode_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';

import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_transitions.dart';
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

  ToolboxRuntime runtimeWith(http.Client client) => ToolboxRuntime.testing(
    catalog: toolboxCatalog,
    store: fixture.store,
    downloads: fixture.manager,
    services: {ExpressService.serviceId: ExpressService(vault: vault, clientFactory: (session) => ExpressClient(session: session, http: ExpressHttp(client: client)))},
  );

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
    expect(find.text('拼多多账号'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('已登录可查绑定手机号与驿站待取件', (tester) async {
    await vault.save(_session);
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ExpressPage(runtime: buildRuntime())));
    await tester.pumpAndSettle();
    expect(find.text('拼多多账号'), findsOneWidget);

    await tester.tap(find.text('绑定手机号'));
    await tester.pumpAndSettle();
    expect(find.textContaining('138****8888'), findsOneWidget);

    await tester.tap(find.text('驿站快递'));
    await tester.pumpAndSettle();
    expect(find.text('驿站待取件'), findsOneWidget);
    expect(find.text('没有待取件'), findsOneWidget);
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

  testWidgets('点码牌全屏出示：码牌原地放大进整屏白底，条码转 90° 铺满长边、亮度调到最高；点一下缩回卡片、亮度复原', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 780));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final brightness = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('github.com/aaassseee/screen_brightness'), (call) async {
      brightness.add(call.method);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('github.com/aaassseee/screen_brightness'), null));
    await vault.save(_session);
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ExpressPage(runtime: buildRuntime())));
    await tester.pumpAndSettle();
    await tester.tap(find.text('身份码'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final inline = tester.getRect(find.byType(BarcodeWidget));
    double angle() => math.atan2(tester.widget<Transform>(find.ancestor(of: find.byType(BarcodeWidget).last, matching: find.byType(Transform)).first).transform.entry(1, 0), tester.widget<Transform>(find.ancestor(of: find.byType(BarcodeWidget).last, matching: find.byType(Transform)).first).transform.entry(0, 0));
    await tester.tap(find.byType(BarcodeWidget));
    await tester.pump();
    expect(brightness, ['setApplicationScreenBrightness']);
    // 飞行途中只看得到一张：卡片里那张隐藏、位置保留；飞的那张转到一半、已离开原位。
    await tester.pump(const Duration(milliseconds: 120));
    expect(tester.widget<Visibility>(find.ancestor(of: find.byType(BarcodeWidget).first, matching: find.byType(Visibility))).visible, isFalse);
    expect(angle(), inExclusiveRange(0.05, math.pi / 2 - .05));
    expect(tester.getCenter(find.byType(BarcodeWidget).last), isNot(inline.center));
    await tester.pump(const Duration(milliseconds: 400));
    expect(angle(), closeTo(math.pi / 2, 1e-6));
    // 转 90° 后条码沿屏幕长边铺开，码值与倒计时随码牌一起出现；整屏白底。
    final zoomed = tester.getRect(find.byType(BarcodeWidget).last);
    expect(zoomed.height, greaterThan(780 * .6));
    expect(zoomed.height, greaterThan(zoomed.width * 2));
    expect(find.text('dd202610190000000000001'), findsNWidgets(2));
    expect(find.textContaining('有效期剩余'), findsNWidgets(2));
    // 全屏页有自己的透明 Material：文字取应用的默认样式，不是框架兜底的黄色双下划线样式。
    expect(DefaultTextStyle.of(tester.element(find.textContaining('有效期剩余').last)).style.debugLabel ?? '', isNot(contains('fallback')));
    expect(find.byWidgetPredicate((widget) => widget is ColoredBox && widget.color == Colors.white), findsOneWidget);

    await tester.tapAt(const Offset(30, 400));
    await tester.pump();
    expect(brightness, ['setApplicationScreenBrightness', 'resetApplicationScreenBrightness']);
    // 缩回到点的那一帧飞的那张正好落在原位；下一帧动画报结束，卡片里那张就露出来，中间不空一帧。
    await tester.pump(campusExit);
    expect(tester.getRect(find.byType(BarcodeWidget).last), inline);
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.widget<Visibility>(find.ancestor(of: find.byType(BarcodeWidget).first, matching: find.byType(Visibility))).visible, isTrue);
    await tester.pump();
    expect(find.byType(BarcodeWidget), findsOneWidget);
    expect(tester.getRect(find.byType(BarcodeWidget)), inline);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('码到期自动换新码并重新倒计时，全屏开着时全屏页也跟着换', (tester) async {
    var issued = 0;
    final runtime = ToolboxRuntime.testing(
      catalog: toolboxCatalog,
      store: fixture.store,
      downloads: fixture.manager,
      services: {
        ExpressService.serviceId: ExpressService(
          vault: vault,
          clientFactory: (session) => ExpressClient(session: session, http: ExpressHttp(client: MockClient((request) async {
            issued++;
            return http.Response(jsonEncode({'success': true, 'error_code': '0', 'result': {'identification_code': 'dd20261020000000000000$issued', 'expire_mills': 2000}}), 200, headers: {'content-type': 'application/json;charset=UTF-8'});
          }))),
        ),
      },
    );
    await vault.save(_session);
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ExpressPage(runtime: runtime)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('身份码'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('有效期剩余 2 秒'), findsOneWidget);
    await tester.tap(find.byType(BarcodeWidget));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('dd202610200000000000001'), findsNWidgets(2));
    // 两秒后到期：自动请求新码，卡片与全屏页都换成新码，倒计时从头开始。
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 50));
    expect(issued, 2);
    expect(find.text('dd202610200000000000002'), findsNWidgets(2));
    expect(find.text('有效期剩余 2 秒'), findsNWidgets(2));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('卡片里的码值 360dp ×1.3 保持一行，放不下就整体缩小，不超出卡片', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 780));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await vault.save(_session);
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.3)), child: child!), home: ExpressPage(runtime: buildRuntime())));
    await tester.pumpAndSettle();
    await tester.tap(find.text('身份码'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final code = find.byType(SelectableText);
    expect(tester.getSize(code).height, lessThan(16 * 1.3 * 2));
    expect(tester.getRect(code).width, lessThanOrEqualTo(360 - 64.0));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('二维码全屏只放大不旋转，返回键关闭', (tester) async {
    await vault.save(_session);
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ExpressPage(runtime: buildRuntime())));
    await tester.pumpAndSettle();
    await tester.tap(find.text('身份码'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('二维码'));
    await tester.pump(const Duration(milliseconds: 400));
    final inline = tester.getSize(find.byType(PrettyQrView));
    await tester.tap(find.byType(PrettyQrView));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(BarcodeWidget), findsNothing);
    final zoomed = tester.getSize(find.byType(PrettyQrView).last);
    expect(zoomed.width, greaterThan(inline.width));
    expect(zoomed.width, closeTo(zoomed.height, .01));
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(PrettyQrView), findsOneWidget);
    expect(find.text('拼多多账号'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('查询时只有点的那个按钮原地转圈、其余暂不可点，不出进度条；失败用提示条，不在卡片里留红字', (tester) async {
    final gate = Completer<void>();
    await vault.save(_session);
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ExpressPage(runtime: runtimeWith(MockClient((request) async {
      await gate.future;
      return http.Response('', 500);
    })))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('绑定手机号'));
    await tester.pump();
    expect(find.text('正在查询'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(tester.widget<OutlinedButton>(find.ancestor(of: find.text('驿站快递'), matching: find.byType(OutlinedButton))).onPressed, isNull);
    gate.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('正在查询'), findsNothing);
    expect(find.text('拼多多返回错误码 500'), findsOneWidget, reason: '只在提示条里出现一次');
    expect(find.ancestor(of: find.text('拼多多返回错误码 500'), matching: find.byType(SnackBar)), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('登录失效回到登录页并写明原因；退出登录在账号卡的⋯里，顶栏不再放', (tester) async {
    await vault.save(_session);
    await tester.pumpWidget(MediaQuery(data: MediaQueryData.fromView(tester.view).copyWith(disableAnimations: true), child: MaterialApp(theme: campusTheme(), home: ExpressPage(runtime: buildRuntime()))));
    await tester.pumpAndSettle();
    expect(find.byTooltip('更多'), findsNothing);
    await tester.tap(find.byTooltip('账号操作'));
    await tester.pumpAndSettle();
    expect(find.text('退出登录'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());

    await vault.save(_session);
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ExpressPage(runtime: runtimeWith(MockClient((request) async => http.Response(jsonEncode({'error_code': 40001}), 200, headers: {'content-type': 'application/json'}))))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('身份码'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('登录拼多多'), findsOneWidget);
    expect(find.text('登录已失效，请重新登录'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('码到期自动刷新没成功：原地写「身份码已过期」并给「刷新」，再失败用提示条', (tester) async {
    var issued = 0;
    await vault.save(_session);
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ExpressPage(runtime: runtimeWith(MockClient((request) async {
      if (++issued > 1) return http.Response('', 503);
      return http.Response(jsonEncode({'success': true, 'error_code': '0', 'result': {'identification_code': 'dd202610200000000000009', 'expire_mills': 1000}}), 200, headers: {'content-type': 'application/json;charset=UTF-8'});
    })))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('身份码'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('有效期剩余 1 秒'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 50));
    expect(issued, 2);
    expect(find.text('身份码已过期'), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, '刷新'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(issued, 3);
    expect(find.text('拼多多返回错误码 503'), findsOneWidget);
    expect(find.text('身份码已过期'), findsOneWidget);
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
