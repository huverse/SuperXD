import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:barcode_widget/barcode_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';

import 'package:webview_flutter/webview_flutter.dart';

import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/toolbox/express/express_anti_content.dart';
import 'package:superxd/toolbox/express/express_client.dart';
import 'package:superxd/toolbox/express/express_controller.dart';
import 'package:superxd/toolbox/express/express_http.dart';
import 'package:superxd/toolbox/express/express_identity_view.dart';
import 'package:superxd/toolbox/express/express_models.dart';
import 'package:superxd/toolbox/express/express_page.dart';
import 'package:superxd/toolbox/express/express_service.dart';
import 'package:superxd/toolbox/express/express_vault.dart';
import 'package:superxd/toolbox/toolbox_catalog.dart';
import 'package:superxd/toolbox/toolbox_models.dart';
import 'package:superxd/toolbox/toolbox_runtime.dart';

import 'toolbox_test_support.dart';

// 默认已读过昵称与取件号（不触发打开页面时的补读）；补读与读不到的情形在各自的用例里另建会话。
const _session = PddSession(accessToken: 'tok', cookie: 'PDDAccessToken=tok', userId: '7209', nickname: '合成昵称', pickupMobile: '150****0000');

http.Response _json(Map<String, Object?> body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json;charset=UTF-8'});

// 合成拼多多服务：按路径回合成数据，身份码固定一串 dd 码，绑定链路全部回成功；calls 按顺序记下请求路径，station 换驿站查询的结果。
http.Client _fakeClient({List<String>? calls, Map<String, Object?>? station, List<http.Request>? requests, Future<void>? trackGate, Future<void>? stationGate, Future<void>? identityGate}) => MockClient((request) async {
  final path = request.url.path;
  calls?.add(path);
  requests?.add(request);
  if (path.endsWith('generate_identification_code')) await identityGate;
  // 物流接口照 10-22 真机的返回形状：不带 success、error_code 是 null；package_info 写这件寄到的手机尾号。
  if (path.endsWith('shipping/track')) {
    await trackGate;
    return _json({
      'error_code': null,
      'shipping': {
        'package_info': '尾号8888 的快递',
        'shipping_name': '合成快递',
        'tracking_number': request.url.queryParameters['tracking_number'],
        'time_forecast': {'time_forecast_desc': '预计明天送达'},
        'traces': [
          {'info': '【合成市】快件已到达合成驿站', 'time': '2026-10-20 15:30:00'},
          {'info': '【合成市】快件已发出', 'time': '2026-10-19 08:00:00'},
        ],
      },
    });
  }
  Map<String, Object?> body;
  if (path.endsWith('express/detail')) {
    body = {'success': true, 'error_code': '0', 'new_binding_list': [{'mobile_id': 'm1', 'mock_mobile': '138****8888', 'alias': '自己', 'commonly_used': true}]};
  } else if (path.endsWith('nickname/query')) {
    body = {'success': true, 'error_code': '0', 'result': {'nickname': '合成小号', 'avatar': ''}};
  } else if (path.endsWith('bind/mobile/station/package')) {
    body = {'success': true, 'error_code': '0'};
  } else if (path.endsWith('station/package')) {
    await stationGate;
    body = {'success': true, 'error_code': '0', 'result': station ?? {'count': 0, 'no_package_mobile_info': {'mobileList': ['8888']}}};
  } else if (path.endsWith('pre/check')) {
    body = {'has_binding_express_mobile': true, 'mobile_id': 'm1', 'mobile_des': '138****8888'};
  } else if (path.endsWith('code/auth/query')) {
    body = {'success': true, 'mobile_id': 'MID'};
  } else if (path.endsWith('code/auth/verify')) {
    body = {'success': true, 'session_id': 'SID'};
  } else if (path.endsWith('new/express/mobile') || path.endsWith('fast/bind/c/mobile') || path.endsWith('mobile/unbind')) {
    body = {'success': true};
  } else {
    body = {'success': true, 'error_code': '0', 'result': {'identification_code': 'dd202610190000000000001', 'expire_mills': 132000, 'mobile_info': {'mobile_info_desc': '已绑定常用手机号：138****8888'}}};
  }
  return _json(body);
});

bool _isLink(String path) => path.endsWith('bind/mobile/station/package');

// 合成驿站码（真实格式：带 station_code 参数的链接，拼多多与微信扫同一张码）。
const _stationUrl = 'https://mdkd.pinduoduo.com/weixin/package?station_code=S000000001';

// 最近一次发到某接口的请求体。
Map<String, Object?> _lastBody(List<http.Request> requests, String pathSuffix) =>
    jsonDecode(requests.lastWhere((request) => request.url.path.endsWith(pathSuffix)).body) as Map<String, Object?>;

// 记下一次性导出的图片字节与类型（驿站码存相册用）；临时文件导出后就删，所以导出当场读。
class _ImagePublisher extends FakePublisher {
  List<int>? bytes;
  String? mimeType;

  @override
  Future<Uri?> publishExternal({required String source, required String filename, required String mimeType}) {
    bytes = File(source).readAsBytesSync();
    this.mimeType = mimeType;
    return super.publishExternal(source: source, filename: filename, mimeType: mimeType);
  }
}

// 存驿站码要真实出图与写文件，假时钟里不会自己走完：交替让出真实事件循环与推一帧，直到条件满足。
Future<void> _settleReal(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
  }
}

// 假 anti_content：绑定测试用，不起真实 WebView（webViewController 为空，页面不挂 WebViewWidget）。
class _FakeAnti implements PddAntiContent {
  @override
  Future<String> generate() async => 'anti';
  @override
  WebViewController? get webViewController => null;
}

// 假的官方安全验证页：不起真实 WebView，点「通过」或「放弃」就关页返回结果；记下打开时带的令牌。
class _FakeVerifyPage extends StatelessWidget {
  const _FakeVerifyPage(this.token);
  final String token;
  static final opened = <String>[];

  @override
  Widget build(BuildContext context) {
    opened.add(token);
    return Scaffold(
      body: Column(children: [
        TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('通过')),
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('放弃')),
      ]),
    );
  }
}

// 从某一点往下拉过下拉刷新的阈值再松手（分几步拉，同真实手势）；越界回弹要挂应用的滚动行为 CampusScrollBehavior。
Future<void> _pull(WidgetTester tester, Offset from) async {
  final gesture = await tester.startGesture(from);
  await gesture.moveBy(const Offset(0, 20));
  await gesture.moveBy(const Offset(0, 40));
  await gesture.moveBy(const Offset(0, 160));
  await tester.pump();
  await gesture.up();
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ToolboxFixture fixture;
  late MemoryExpressVault vault;
  late Directory temp;

  ToolboxRuntime runtimeWith(http.Client client) => ToolboxRuntime.testing(
    catalog: toolboxCatalog,
    store: fixture.store,
    downloads: fixture.manager,
    services: {ExpressService.serviceId: ExpressService(vault: vault, clientFactory: (session) => ExpressClient(session: session, http: ExpressHttp(client: client)))},
  );

  ToolboxRuntime buildRuntime({
    List<String>? calls,
    Map<String, Object?>? station,
    List<http.Request>? requests,
    ToolboxQrScan? scan,
    ToolboxFilePublisher? publisher,
    Future<bool> Function(Uri uri)? launch,
    Future<void>? trackGate,
    Future<void>? stationGate,
    Future<void>? identityGate,
    Widget Function(String token)? verifyPage,
    ToolboxShortcutPin? pin,
  }) => ToolboxRuntime.testing(
    catalog: toolboxCatalog,
    store: fixture.store,
    downloads: fixture.manager,
    scanQrCode: scan,
    pinShortcut: pin,
    services: {
      ExpressService.serviceId: ExpressService(
        vault: vault,
        clientFactory: (session) => ExpressClient(session: session, http: ExpressHttp(client: _fakeClient(calls: calls, station: station, requests: requests, trackGate: trackGate, stationGate: stationGate, identityGate: identityGate))),
        antiContent: _FakeAnti(),
        filePublisher: () => publisher ?? FakePublisher(),
        temporaryDirectory: () async => temp,
        launchExternal: launch ?? (uri) async => true,
        verifyPage: verifyPage ?? _FakeVerifyPage.new,
      ),
    },
  );

  setUp(() async {
    fixture = ToolboxFixture();
    await fixture.initialize();
    vault = MemoryExpressVault();
    temp = Directory.systemTemp.createTempSync('express_ui_test');
  });

  tearDown(() async {
    await fixture.close();
    temp.deleteSync(recursive: true);
  });

  testWidgets('未登录显示登录入口', (tester) async {
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ExpressPage(runtime: buildRuntime())));
    await tester.pumpAndSettle();
    expect(find.text('登录拼多多'), findsOneWidget);
    expect(find.text('拼多多账号'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('已登录可查驿站待取件；绑定手机号打开管理弹层列出已绑号', (tester) async {
    await vault.save(_session);
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ExpressPage(runtime: buildRuntime())));
    await tester.pumpAndSettle();
    expect(find.text('合成昵称'), findsOneWidget);

    await tester.tap(find.text('驿站快递'));
    await tester.pumpAndSettle();
    expect(find.text('驿站待取件'), findsOneWidget);
    expect(find.text('没有待取件'), findsOneWidget);
    expect(find.textContaining('8888'), findsWidgets);

    // 绑定手机号打开取件手机号管理弹层：列出已绑号，并有「绑定其他手机号」。
    await tester.tap(find.text('绑定手机号'));
    await tester.pumpAndSettle();
    expect(find.text('取件手机号'), findsOneWidget);
    expect(find.text('138****8888（自己）'), findsOneWidget);
    expect(find.text('绑定其他手机号'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  // 真机反馈（1.0.0-alpha.7 构建号 8）：内容不满一屏时账号卡与按钮整块挤在屏幕中间。整页滚动区按内容收缩高度，外层不能居中。
  testWidgets('已登录内容不满一屏时从顶栏下面开始排，不挤到屏幕中间', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 780));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await vault.save(_session);
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ExpressPage(runtime: buildRuntime())));
    await tester.pumpAndSettle();
    final appBar = tester.getRect(find.byType(AppBar));
    double accountTop() => tester.getRect(find.ancestor(of: find.text('合成昵称'), matching: find.byType(CampusSurface)).first).top;
    expect(accountTop() - appBar.bottom, lessThanOrEqualTo(24));

    await tester.tap(find.text('驿站快递'));
    await tester.pumpAndSettle();
    expect(find.text('没有待取件'), findsOneWidget);
    expect(accountTop() - appBar.bottom, lessThanOrEqualTo(24));
    await tester.pumpWidget(const SizedBox());
  });

  // 用户反馈：快递页下拉没有任何反馈（以前已登录内容是按内容收缩的滚动区，不满一屏时空白处拉不动）。
  testWidgets('整页可下拉：空白处也能拉，下拉重查驿站快递、按钮不跟着转；扫过驿站码的重查同一站点', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 780));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final requests = <http.Request>[];
    final gate = Completer<void>();
    await vault.save(_session);
    await vault.saveStationLinked(true);
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), scrollBehavior: const CampusScrollBehavior(), home: ExpressPage(runtime: buildRuntime(
      requests: requests,
      stationGate: gate.future,
      station: const {'count': 0, 'station_name': '合成驿站'},
      scan: (context, hint, check) async => _stationUrl,
    ))));
    await tester.pumpAndSettle();
    int stationQueries() => requests.where((request) => request.url.path.endsWith('express_trackbox/station/package')).length;

    // 从按钮下面的空白处往下拉：拉过阈值松手即开始刷新。
    await _pull(tester, const Offset(180, 650));
    await tester.pump(const Duration(milliseconds: 100));
    expect(stationQueries(), 1);
    // 刷新中只转下拉指示：按钮不写「正在查询」，但都暂不可点（一次只跑一个请求）。
    expect(find.text('正在查询'), findsNothing);
    expect(tester.widget<OutlinedButton>(find.ancestor(of: find.text('驿站快递'), matching: find.byType(OutlinedButton))).onPressed, isNull);
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('没有待取件'), findsOneWidget);
    expect(_lastBody(requests, 'express_trackbox/station/package').containsKey('station_code'), isFalse);

    // 扫过驿站码后再下拉：重查同一个站点，不退回全部驿站。
    await tester.tap(find.text('扫驿站码'));
    await tester.pumpAndSettle();
    expect(find.text('当前站点：合成驿站'), findsOneWidget);
    await _pull(tester, const Offset(180, 300));
    await tester.pumpAndSettle();
    expect(stationQueries(), 3);
    expect(_lastBody(requests, 'express_trackbox/station/package')['station_code'], 'S000000001');
    expect(find.text('当前站点：合成驿站'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('下拉刷新后取走的件原地收起、没取走的不动；尾号查过的件不再补查', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 780));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final requests = <http.Request>[];
    final parcels = [
      {'pick_code': '取件码 3-2-1001', 'shipping_name': '合成快递', 'shipping_id': 1, 'tracking_number': 'SX0000000001'},
      {'pick_code': '取件码 3-2-1002', 'shipping_name': '合成快递', 'shipping_id': 1, 'tracking_number': 'SX0000000002'},
    ];
    final station = <String, Object?>{
      'count': 2,
      'combine_list': [{'company_name': '合成驿站一号', 'address': '测试路 1 号', 'combine_track_list': parcels}],
    };
    await vault.save(_session);
    await vault.saveStationLinked(true);
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), scrollBehavior: const CampusScrollBehavior(), home: ExpressPage(runtime: buildRuntime(requests: requests, station: station))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('驿站快递'));
    await tester.pumpAndSettle();
    expect(find.text('取件码 3-2-1001'), findsOneWidget);
    expect(find.text('取件码 3-2-1002'), findsOneWidget);
    int tracks() => requests.where((request) => request.url.path.endsWith('shipping/track')).length;
    expect(tracks(), 2);
    final kept = tester.element(find.text('取件码 3-2-1001'));

    // 第二件取走了：下拉后那一行原地收起淡出，再从列表里移除；留下的那一行还是原来那个，不重建、不跳。
    parcels.removeAt(1);
    station['count'] = 1;
    await _pull(tester, const Offset(180, 200));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('1 件待取'), findsOneWidget);
    expect(find.text('取件码 3-2-1002'), findsOneWidget, reason: '收起途中还在原位');
    await tester.pumpAndSettle();
    expect(find.text('取件码 3-2-1002'), findsNothing);
    expect(identical(tester.element(find.text('取件码 3-2-1001')), kept), isTrue);
    expect(tracks(), 2, reason: '留下的件尾号已存本机，下拉不再补查');
    await tester.pumpWidget(const SizedBox());
  });

  // 真机反馈：弹层先放整页加载动画撑到接近全屏、读完再缩回内容高度（突闪）。改为先读后开，弹层一出来就是最终高度。
  testWidgets('绑定手机号先读后开：读取时按钮原地转圈、弹层还没出；弹出那一帧就是列表与最终高度', (tester) async {
    final gate = Completer<void>();
    await vault.save(_session);
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ExpressPage(runtime: runtimeWith(MockClient((request) async {
      if (request.url.path.endsWith('pre/check')) return _json({'has_binding_express_mobile': true});
      await gate.future;
      return _json({'success': true, 'error_code': '0', 'new_binding_list': [{'mobile_id': 'm1', 'mock_mobile': '138****8888'}]});
    })))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('绑定手机号'));
    await tester.pump();
    expect(find.text('读取中'), findsOneWidget);
    expect(find.text('取件手机号'), findsNothing);
    expect(tester.widget<OutlinedButton>(find.ancestor(of: find.text('驿站快递'), matching: find.byType(OutlinedButton))).onPressed, isNull);

    gate.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.text('138****8888'), findsOneWidget);
    expect(find.byType(CampusLoading), findsNothing);
    final opening = tester.getSize(find.byType(CampusSheetPanel));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(CampusSheetPanel)), opening);
    expect(find.text('读取中'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('第一次查驿站先补关联一次并记在本机，再查不再补；包裹按驿站列出取件码与快递信息', (tester) async {
    final calls = <String>[];
    await vault.save(_session);
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ExpressPage(runtime: buildRuntime(calls: calls, station: const {
      'count': 1,
      'combine_list': [
        {'company_name': '合成驿站一号', 'address': '测试路 1 号', 'combine_track_list': [{'pick_code': '取件码 3-2-1001', 'shipping_name': '合成快递', 'tracking_number': 'SX0000000001'}]},
      ],
    }))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('驿站快递'));
    await tester.pumpAndSettle();
    expect(calls.where(_isLink).length, 1);
    expect(calls.indexWhere(_isLink), lessThan(calls.lastIndexWhere((path) => path.endsWith('station/package') && !_isLink(path))));
    expect(await vault.stationLinked(), isTrue);
    expect(find.text('1 件待取'), findsOneWidget);
    expect(find.text('合成驿站一号'), findsOneWidget);
    expect(find.text('测试路 1 号'), findsOneWidget);
    expect(find.text('取件码 3-2-1001'), findsOneWidget);
    expect(find.textContaining('SX0000000001'), findsOneWidget);

    await tester.tap(find.text('驿站快递'));
    await tester.pumpAndSettle();
    expect(calls.where(_isLink).length, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('补关联失败不挡查询，不记已关联，下次查询再补', (tester) async {
    var links = 0;
    await vault.save(_session);
    final runtime = ToolboxRuntime.testing(
      catalog: toolboxCatalog,
      store: fixture.store,
      downloads: fixture.manager,
      services: {
        ExpressService.serviceId: ExpressService(
          vault: vault,
          clientFactory: (session) => ExpressClient(session: session, http: ExpressHttp(client: MockClient((request) async {
            if (_isLink(request.url.path)) {
              links++;
              return http.Response('', 403);
            }
            return _json({'success': true, 'error_code': '0', 'result': {'count': 0}});
          }))),
          antiContent: _FakeAnti(),
        ),
      },
    );
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ExpressPage(runtime: runtime)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('驿站快递'));
    await tester.pumpAndSettle();
    expect(find.text('没有待取件'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    expect(await vault.stationLinked(), isFalse);
    await tester.tap(find.text('驿站快递'));
    await tester.pumpAndSettle();
    expect(links, 2);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('没有待取件时手机尾号同官方只写前两个，还有更多补「等」', (tester) async {
    await vault.save(_session);
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ExpressPage(runtime: buildRuntime(station: const {
      'count': 0,
      'no_package_mobile_info': {'mobileList': ['8888', '6666'], 'largerThan2': true},
    }))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('驿站快递'));
    await tester.pumpAndSettle();
    expect(find.text('手机尾号 8888、6666等'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('扫驿站码从链接里取站点码去查并写当前站点；扫过驿站码后身份码带上这个站，普通查询后不再带', (tester) async {
    final requests = <http.Request>[];
    String? Function(String raw)? accept;
    await vault.save(_session);
    await vault.saveStationLinked(true);
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ExpressPage(runtime: buildRuntime(
      requests: requests,
      station: const {'count': 0, 'station_name': '合成驿站'},
      scan: (context, hint, check) async {
        accept = check;
        return _stationUrl;
      },
    ))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('扫驿站码'));
    await tester.pumpAndSettle();
    // 扫码页按同一规则当场拦下不是驿站码的二维码。
    expect(accept!('https://example.com/station?foo=bar'), '不是驿站的二维码');
    expect(accept!(_stationUrl), isNull);
    expect(_lastBody(requests, 'express_trackbox/station/package')['station_code'], 'S000000001');
    expect(_lastBody(requests, 'express_trackbox/station/package')['entry_source'], '4');
    expect(find.text('当前站点：合成驿站'), findsOneWidget);

    await tester.tap(find.text('身份码'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(_lastBody(requests, 'generate_identification_code')['station_code'], 'S000000001');

    // 身份码卡滚进可视区后按钮可能被滚出屏幕：等滚动走完、滚回按钮再点（滚动途中不接点按）。
    await tester.pump(const Duration(milliseconds: 400));
    await tester.ensureVisible(find.text('驿站快递'));
    await tester.pump();
    await tester.tap(find.text('驿站快递'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(_lastBody(requests, 'express_trackbox/station/package').containsKey('station_code'), isFalse);
    await tester.tap(find.text('身份码'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(_lastBody(requests, 'generate_identification_code').containsKey('station_code'), isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('只能微信扫码取件：不写没有待取件；扫过驿站码时「去微信取件」把驿站码存进相册、提示从相册选，再拉起微信', (tester) async {
    final publisher = _ImagePublisher();
    final launched = <Uri>[];
    await vault.save(_session);
    await vault.saveStationLinked(true);
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ExpressPage(runtime: buildRuntime(
      station: const {'count': 0, 'station_name': '合成驿站', 'only_wx_scan': true},
      scan: (context, hint, check) async => _stationUrl,
      publisher: publisher,
      launch: (uri) async {
        launched.add(uri);
        return true;
      },
    ))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('扫驿站码'));
    await tester.pumpAndSettle();
    expect(find.text('这个账号目前只能用微信查询待取件'), findsOneWidget);
    expect(find.textContaining('拼多多暂停'), findsNothing);
    expect(find.text('没有待取件'), findsNothing);

    await tester.tap(find.text('去微信取件'));
    await _settleReal(tester, () => find.text('驿站码已存到相册').evaluate().isNotEmpty);
    await tester.pumpAndSettle();
    expect(find.text('驿站码已存到相册'), findsOneWidget);
    expect(find.textContaining('选这张驿站码查询取件'), findsOneWidget);
    expect(publisher.externalFilename, '驿站码-S000000001.png');
    expect(publisher.mimeType, 'image/png');
    expect(publisher.bytes!.take(4), [0x89, 0x50, 0x4E, 0x47]);
    await tester.tap(find.widgetWithText(FilledButton, '打开微信'));
    await tester.pumpAndSettle();
    expect(launched, [Uri.parse('weixin://')]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('只能微信取件但没扫过驿站码：不存图，提示扫驿站的码查询取件；拉不起微信时说明；身份码照常生成', (tester) async {
    final publisher = _ImagePublisher();
    await vault.save(_session);
    await vault.saveStationLinked(true);
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ExpressPage(runtime: buildRuntime(
      station: const {'count': 0, 'only_wx_scan': true},
      publisher: publisher,
      launch: (uri) async => false,
    ))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('驿站快递'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('去微信取件'));
    await tester.pumpAndSettle();
    expect(find.textContaining('扫驿站的二维码查询取件'), findsOneWidget);
    expect(publisher.calls, 0);
    await tester.tap(find.widgetWithText(FilledButton, '打开微信'));
    await tester.pumpAndSettle();
    expect(find.text('没有找到微信'), findsOneWidget);

    await tester.tap(find.text('身份码'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(ExpressIdentityView), findsOneWidget);
    expect(find.textContaining('驿站可能不认'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('近一周已取出列在驿站卡片里；点「物流」先读后开：读取时只有那一行转圈、弹层未出，读完弹出物流详情', (tester) async {
    final gate = Completer<void>();
    final requests = <http.Request>[];
    await vault.save(_session);
    await vault.saveStationLinked(true);
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ExpressPage(runtime: buildRuntime(
      requests: requests,
      trackGate: gate.future,
      station: const {
        'count': 0,
        'package_out_list': [
          {'address': '测试路 1 号', 'operate_time': '10-20 15:30', 'shipping_name': '合成快递', 'tracking_number': 'SX0000000002', 'jump_url': '/track?tracking_number=SX0000000002&shipping_id=102&source_type=3'},
          {'address': '测试路 1 号', 'operate_time': '10-19 09:10', 'shipping_name': '合成快递', 'tracking_number': 'SX0000000003', 'shipping_id': '103'},
        ],
      },
    ))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('驿站快递'));
    await tester.pumpAndSettle();
    expect(find.text('没有待取件'), findsOneWidget);
    expect(find.text('近一周已取出 2 件'), findsOneWidget);
    expect(find.text('取件时间 10-20 15:30'), findsOneWidget);
    expect(find.textContaining('SX0000000002'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, '物流').first);
    await tester.pump();
    expect(find.text('物流详情'), findsNothing);
    expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '物流').last).onPressed, isNull, reason: '查询中其他行不能再点');
    final track = requests.lastWhere((request) => request.url.path.endsWith('shipping/track'));
    expect(track.url.queryParameters, {'tracking_number': 'SX0000000002', 'shipping_id': '102', 'entry_source': '9', 'source_type': '3'});

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('物流详情'), findsOneWidget);
    expect(find.text('预计明天送达'), findsOneWidget);
    expect(find.text('【合成市】快件已到达合成驿站'), findsOneWidget);
    expect(find.text('2026-10-19 08:00:00'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('待取件也能查物流（带包裹的 shipping_id）；查不到用提示条，不弹空弹层', (tester) async {
    final requests = <http.Request>[];
    await vault.save(_session);
    await vault.saveStationLinked(true);
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ExpressPage(runtime: buildRuntime(
      requests: requests,
      station: const {
        'count': 1,
        'combine_list': [
          {'company_name': '合成驿站一号', 'combine_track_list': [{'pick_code': '1-1-0001', 'shipping_name': '合成快递', 'tracking_number': 'SX0000000001', 'shipping_id': 101}]},
        ],
      },
    ))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('驿站快递'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, '物流'));
    await tester.pumpAndSettle();
    expect(requests.lastWhere((request) => request.url.path.endsWith('shipping/track')).url.queryParameters['shipping_id'], '101');
    expect(find.text('物流详情'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());

    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ExpressPage(runtime: runtimeWith(MockClient((request) async {
      if (request.url.path.endsWith('shipping/track')) return _json({'error_code': 1000101, 'error_message': '暂无该运单号物流轨迹信息'});
      return _json({'success': true, 'error_code': '0', 'result': {'count': 1, 'combine_list': [{'combine_track_list': [{'pick_code': '1-1-0001', 'tracking_number': 'SX0000000001'}]}]}});
    })))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('驿站快递'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, '物流'));
    await tester.pumpAndSettle();
    expect(find.text('暂无该运单号物流轨迹信息'), findsOneWidget);
    expect(find.text('物流详情'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  test('登录校验：只读接口明确回未登录才拦，网络与服务器错误不拦', () async {
    Future<bool> verify(http.Response Function() respond) async {
      final controller = ExpressController(ExpressService(
        vault: vault,
        clientFactory: (session) => ExpressClient(session: session, http: ExpressHttp(client: MockClient((request) async => respond()))),
      ));
      final usable = await controller.verifySession(_session);
      controller.dispose();
      return usable;
    }

    expect(await verify(() => _json({'has_binding_express_mobile': true})), isTrue);
    expect(await verify(() => _json({'error_code': 40001})), isFalse);
    expect(await verify(() => http.Response('', 424)), isFalse);
    expect(await verify(() => http.Response('', 500)), isTrue);
  });

  // 真机反馈：账号卡只写「拼多多账号」，认不出登的是哪个账号；已绑号的账号拿不到登录手机号，改写昵称与常用取件号。
  testWidgets('账号卡标题写拼多多昵称、下面写常用取件号（还绑了别的号补「等」）；都没读到时照旧写「拼多多账号」与账号号', (tester) async {
    await vault.save(_session.withAccount(pickupMore: true));
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ExpressPage(runtime: buildRuntime())));
    await tester.pumpAndSettle();
    final title = find.text('合成昵称');
    expect(title, findsOneWidget);
    expect(tester.getRect(title).top, lessThan(tester.getRect(find.text('取件号 150****0000 等')).top));
    expect(find.textContaining('7209'), findsNothing);
    await tester.pumpWidget(const SizedBox());

    await vault.save(const PddSession(accessToken: 'tok', cookie: 'PDDAccessToken=tok', userId: '7209', nickname: '合成昵称', pickupMobile: ''));
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ExpressPage(runtime: buildRuntime())));
    await tester.pumpAndSettle();
    expect(find.text('拼多多账号'), findsOneWidget, reason: '有昵称、没绑取件号');
    await tester.pumpWidget(const SizedBox());

    await vault.save(const PddSession(accessToken: 'tok', cookie: 'PDDAccessToken=tok', userId: '7209', nickname: '', pickupMobile: ''));
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ExpressPage(runtime: buildRuntime())));
    await tester.pumpAndSettle();
    expect(find.text('拼多多账号'), findsOneWidget);
    expect(find.text('账号 7209'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('之前登录的会话没读过昵称与取件号：打开快递页补读一次并存回会话，再打开不再读；登录后同样读一次', (tester) async {
    final calls = <String>[];
    const fresh = PddSession(accessToken: 'tok', cookie: 'PDDAccessToken=tok', userId: '7209');
    await vault.save(fresh);
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ExpressPage(runtime: buildRuntime(calls: calls))));
    await tester.pumpAndSettle();
    expect(calls.where((path) => path.endsWith('nickname/query')), hasLength(1));
    expect(calls.where((path) => path.endsWith('express/detail')), hasLength(1));
    expect(find.text('合成小号'), findsOneWidget);
    expect(find.text('取件号 138****8888'), findsOneWidget);
    final saved = await vault.load();
    expect((saved?.accessToken, saved?.nickname, saved?.pickupMobile, saved?.pickupMore), ('tok', '合成小号', '138****8888', false));
    await tester.pumpWidget(const SizedBox());

    calls.clear();
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ExpressPage(runtime: buildRuntime(calls: calls))));
    await tester.pumpAndSettle();
    expect(calls, isEmpty);
    expect(find.text('合成小号'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());

    // 登录（登录页确认会话后交来的是没读过的会话）：存好会话后读一次。
    await vault.deleteAll();
    final controller = ExpressController(ExpressService(
      vault: vault,
      clientFactory: (session) => ExpressClient(session: session, http: ExpressHttp(client: _fakeClient())),
    ));
    await controller.initialize();
    await controller.onLoggedIn(fresh);
    // 假时钟里不能用 pumpEventQueue（它靠计时器让出）：推几帧让后台读完。
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    expect((controller.session?.nickname, (await vault.load())?.pickupMobile), ('合成小号', '138****8888'));
    controller.dispose();
  });

  test('补读昵称与取件号途中退出登录：读完不把会话写回存储', () async {
    final gate = Completer<void>();
    await vault.save(const PddSession(accessToken: 'tok', userId: '7209'));
    final controller = ExpressController(ExpressService(
      vault: vault,
      clientFactory: (session) => ExpressClient(session: session, http: ExpressHttp(client: MockClient((request) async {
        await gate.future;
        if (request.url.path.endsWith('nickname/query')) return _json({'success': true, 'error_code': '0', 'result': {'nickname': '合成小号'}});
        return _json({'success': true, 'error_code': '0', 'new_binding_list': [{'mobile_id': 'm1', 'mock_mobile': '138****8888'}]});
      }))),
    ));
    await controller.initialize();
    await controller.logout();
    gate.complete();
    await pumpEventQueue();
    expect(controller.loggedIn, isFalse);
    expect(await vault.load(), isNull);
    controller.dispose();
  });

  testWidgets('打开取件手机号管理读到列表后，账号卡的取件号跟着更新（常用号优先，多个补「等」）', (tester) async {
    await vault.save(_session);
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ExpressPage(runtime: runtimeWith(MockClient((request) async {
      if (request.url.path.endsWith('pre/check')) return _json({'has_binding_express_mobile': true});
      return _json({'success': true, 'error_code': '0', 'new_binding_list': [
        {'mobile_id': 'm1', 'mock_mobile': '138****1111'},
        {'mobile_id': 'm2', 'mock_mobile': '139****2222', 'commonly_used': true},
      ]});
    })))));
    await tester.pumpAndSettle();
    expect(find.text('取件号 150****0000'), findsOneWidget);
    await tester.tap(find.text('绑定手机号'));
    await tester.pumpAndSettle();
    expect(find.text('取件号 139****2222 等'), findsOneWidget);
    expect((await vault.load())?.pickupMobile, '139****2222');
    await tester.pumpWidget(const SizedBox());
  });

  // 真机反馈：待取件看不出是寄给哪个手机号的；快递公司太显眼。驿站查询不给手机号，按件补查物流接口的 package_info 取尾号。
  testWidgets('待取件按寄到的手机尾号分组：组按尾号排、未知的放最后；首屏不写快递公司；同一件页面开着时只补查一次', (tester) async {
    final tracks = <String>[];
    await vault.save(_session);
    await vault.saveStationLinked(true);
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ExpressPage(runtime: runtimeWith(MockClient((request) async {
      if (request.url.path.endsWith('shipping/track')) {
        final number = request.url.queryParameters['tracking_number']!;
        tracks.add(number);
        if (number == 'SX0000000003') return http.Response('', 500);
        return _json({'error_code': null, 'shipping': {'shipping_name': '合成快递', 'package_info': number == 'SX0000000002' ? '尾号1234 的快递' : '尾号5678 的快递'}});
      }
      return _json({'success': true, 'error_code': '0', 'result': {
        'count': 3,
        'combine_list': [
          {
            'company_name': '合成驿站一号',
            'address': '合成驿站一号',
            'combine_track_list': [
              {'pick_code': '取件码 6-1-0101', 'shipping_name': '合成快递', 'tracking_number': 'SX0000000001', 'shipping_id': 1},
              {'pick_code': '取件码 B2-1-0102', 'shipping_name': '其他', 'tracking_number': 'SX0000000002', 'shipping_id': 999999},
              {'pick_code': '取件码 5-2-0001', 'shipping_name': '合成快递', 'tracking_number': 'SX0000000003', 'shipping_id': 1},
            ],
          },
        ],
      }});
    })))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('驿站快递'));
    await tester.pumpAndSettle();
    expect(tracks.toSet(), {'SX0000000001', 'SX0000000002', 'SX0000000003'});
    double top(String text) => tester.getRect(find.text(text)).top;
    expect(find.text('尾号 1234 · 1 件'), findsOneWidget);
    expect(find.text('尾号 5678 · 1 件'), findsOneWidget);
    expect(find.text('尾号未知 · 1 件'), findsOneWidget);
    expect(top('尾号 1234 · 1 件'), lessThan(top('取件码 B2-1-0102')));
    expect(top('取件码 B2-1-0102'), lessThan(top('尾号 5678 · 1 件')));
    expect(top('尾号 5678 · 1 件'), lessThan(top('取件码 6-1-0101')));
    expect(top('取件码 6-1-0101'), lessThan(top('尾号未知 · 1 件')));
    expect(find.text('合成驿站一号'), findsOneWidget, reason: '站址与站名一样时不重复写');
    expect(find.textContaining('合成快递'), findsNothing, reason: '首屏不写快递公司');
    expect(find.text('SX0000000001'), findsOneWidget);

    // 再查一次：查到过尾号的不再补查，没查到的再试一次。
    tracks.clear();
    await tester.tap(find.text('驿站快递'));
    await tester.pumpAndSettle();
    expect(tracks, ['SX0000000003']);
    await tester.pumpWidget(const SizedBox());
  });

  // 真机上短时间反复查物流触发了拼多多风控（54001），用户选「尾号存本机、同一件只查一次」。
  testWidgets('尾号存本机：重开快递页不再补查；取走的件（不在待取件里了）尾号随之删掉', (tester) async {
    final tracks = <String>[];
    var parcels = ['SX0000000001', 'SX0000000002'];
    ToolboxRuntime runtime() => runtimeWith(MockClient((request) async {
      if (request.url.path.endsWith('shipping/track')) {
        tracks.add(request.url.queryParameters['tracking_number']!);
        return _json({'error_code': null, 'shipping': {'package_info': '尾号5678 的快递'}});
      }
      return _json({'success': true, 'error_code': '0', 'result': {
        'count': parcels.length,
        'combine_list': [
          {'company_name': '合成驿站一号', 'combine_track_list': [for (final number in parcels) {'pick_code': '1-1-$number', 'tracking_number': number, 'shipping_id': 1}]},
        ],
      }});
    }));
    await vault.save(_session);
    await vault.saveStationLinked(true);
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ExpressPage(runtime: runtime())));
    await tester.pumpAndSettle();
    await tester.tap(find.text('驿站快递'));
    await tester.pumpAndSettle();
    expect(tracks, hasLength(2));
    expect(await vault.ownerTails(), {'1|SX0000000001': '5678', '1|SX0000000002': '5678'});
    await tester.pumpWidget(const SizedBox());

    tracks.clear();
    parcels = ['SX0000000002'];
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ExpressPage(runtime: runtime())));
    await tester.pumpAndSettle();
    await tester.tap(find.text('驿站快递'));
    await tester.pumpAndSettle();
    expect(tracks, isEmpty, reason: '重开页面后已存的尾号不再补查');
    expect(find.text('尾号 5678 · 1 件'), findsOneWidget);
    expect(await vault.ownerTails(), {'1|SX0000000002': '5678'});
    await tester.pumpWidget(const SizedBox());
  });

  // 10-25 用户反馈：在拼多多里自己添加的件写「尾号未知」。官方物流页对驿站里的件按 order_sn 查驿站物流；用户选「每次查驿站都重查尾号未知的件」。数据合成。
  testWidgets('驿站里带 order_sn 的件按 order_sn 补查尾号；查成功但没给尾号的不存本机，下次查驿站再查', (tester) async {
    final tracks = <String>[];
    var tail = '';
    await vault.save(_session);
    await vault.saveStationLinked(true);
    // 旧版本把查成功但没给尾号的件存成了空串。
    await vault.saveOwnerTails({'1|SX0000000005': ''});
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ExpressPage(runtime: runtimeWith(MockClient((request) async {
      if (request.url.path.endsWith('shipping/track')) {
        tracks.add(request.url.path);
        return _json({'error_code': null, 'shipping': {'shipping_name': '合成快递', if (tail.isNotEmpty) 'package_info': '尾号$tail 的快递'}});
      }
      return _json({'success': true, 'error_code': '0', 'result': {
        'count': 1,
        'combine_list': [
          {'company_name': '合成驿站一号', 'combine_track_list': [
            {'pick_code': '取件码 7-1-0001', 'tracking_number': 'SX0000000005', 'shipping_id': 1, 'order_sn': 'SN0000000005', 'jump_url': '/track?order_sn=SN0000000005&source_type=2'},
          ]},
        ],
      }});
    })))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('驿站快递'));
    await tester.pumpAndSettle();
    expect(tracks, ['/api/express/dsd/trackbox/shipping/track'], reason: '旧版存下的空尾号不算查到过');
    expect(find.text('尾号未知 · 1 件'), findsOneWidget);
    expect(await vault.ownerTails(), isEmpty, reason: '没给尾号的不存本机');

    tracks.clear();
    tail = '4321';
    await tester.tap(find.text('驿站快递'));
    await tester.pumpAndSettle();
    expect(tracks, hasLength(1), reason: '下次查驿站再查');
    expect(find.text('尾号 4321 · 1 件'), findsOneWidget);
    expect(await vault.ownerTails(), {'1|SX0000000005': '4321'});
    await tester.pumpWidget(const SizedBox());
  });

  // 真机：反复查物流后拼多多回 54001 并带 verify_auth_token（带不带 anti-content 都一样）；官方页面这时跳官方安全验证页。
  testWidgets('点「物流」碰到拼多多要求安全验证：打开官方验证页，通过后带上令牌再查一次；放弃就用提示条说明', (tester) async {
    _FakeVerifyPage.opened.clear();
    final tokens = <String?>[];
    await vault.save(_session);
    await vault.saveStationLinked(true);
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ExpressPage(runtime: ToolboxRuntime.testing(
      catalog: toolboxCatalog,
      store: fixture.store,
      downloads: fixture.manager,
      services: {
        ExpressService.serviceId: ExpressService(
          vault: vault,
          verifyPage: _FakeVerifyPage.new,
          clientFactory: (session) => ExpressClient(session: session, http: ExpressHttp(client: MockClient((request) async {
            if (request.url.path.endsWith('shipping/track')) {
              final token = request.headers['VerifyAuthToken'];
              tokens.add(token);
              if (token == null) return _json({'error_code': 54001, 'verify_auth_token': 'VT-1', 'shipping': null});
              return _json({'error_code': null, 'shipping': {'shipping_name': '合成快递', 'package_info': '尾号5678 的快递', 'traces': [{'info': '【合成市】快件已到达合成驿站', 'time': '2026-10-20 15:30:00'}]}});
            }
            return _json({'success': true, 'error_code': '0', 'result': {'count': 1, 'combine_list': [{'company_name': '合成驿站一号', 'combine_track_list': [{'pick_code': '1-1-0001', 'tracking_number': 'SX0000000001', 'shipping_id': 1}]}]}});
          }))),
        ),
      },
    ))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('驿站快递'));
    await tester.pumpAndSettle();
    // 查驿站后的自动补查碰到它不弹验证页，归尾号未知。
    expect(_FakeVerifyPage.opened, isEmpty);
    expect(find.text('尾号未知 · 1 件'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, '物流'));
    await tester.pumpAndSettle();
    expect(_FakeVerifyPage.opened, ['VT-1']);
    await tester.tap(find.text('放弃'));
    await tester.pumpAndSettle();
    expect(find.text('物流详情'), findsNothing);
    expect(find.text('拼多多要求先完成安全验证'), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    await tester.tap(find.widgetWithText(OutlinedButton, '物流'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('通过'));
    await tester.pumpAndSettle();
    expect(find.text('物流详情'), findsOneWidget);
    expect(tokens.last, 'VT-1', reason: '通过后同官方带上验证令牌再查');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('自动补查尾号碰到安全验证就停：这一轮剩下的件不再请求', (tester) async {
    final tracks = <String>[];
    await vault.save(_session);
    await vault.saveStationLinked(true);
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ExpressPage(runtime: runtimeWith(MockClient((request) async {
      if (request.url.path.endsWith('shipping/track')) {
        tracks.add(request.url.queryParameters['tracking_number']!);
        return _json({'error_code': 54001, 'verify_auth_token': 'VT-1'});
      }
      return _json({'success': true, 'error_code': '0', 'result': {
        'count': 7,
        'combine_list': [
          {'company_name': '合成驿站一号', 'combine_track_list': [for (var index = 1; index <= 7; index++) {'pick_code': '1-1-000$index', 'tracking_number': 'SX000000000$index', 'shipping_id': 1}]},
        ],
      }});
    })))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('驿站快递'));
    await tester.pumpAndSettle();
    expect(tracks, hasLength(5), reason: '第一批 5 件都要求验证，第二批不再发');
    expect(find.text('尾号未知 · 7 件'), findsOneWidget);
    expect(find.text('拼多多要求先完成安全验证'), findsNothing, reason: '自动补查不打扰');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('绑定其他手机号：输手机号发验证码、输验证码完成绑定，弹层回到列表并提示已绑定；绑定后紧接着关联驿站包裹', (tester) async {
    final calls = <String>[];
    await vault.save(_session);
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ExpressPage(runtime: buildRuntime(calls: calls))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('绑定手机号'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('绑定其他手机号'));
    await tester.pumpAndSettle();
    expect(find.text('绑定其他手机号'), findsWidgets);
    // 没发验证码前不进验证码步骤。
    expect(find.widgetWithText(TextField, '验证码'), findsNothing);
    await tester.enterText(find.widgetWithText(TextField, '手机号'), '13800000000');
    await tester.tap(find.text('发送验证码'));
    await tester.pumpAndSettle();
    // 进入验证码步骤。
    expect(find.textContaining('验证码已发送至 13800000000'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, '验证码'), '123456');
    await tester.tap(find.text('确认绑定'));
    await tester.pumpAndSettle();
    // 回到弹层列表，提示已绑定。
    expect(find.text('取件手机号'), findsOneWidget);
    expect(find.text('已绑定'), findsOneWidget);
    // 同官方：绑定成功后紧接着把这个号已到站的包裹关联进本账号。
    final bindAt = calls.indexWhere((path) => path.endsWith('new/express/mobile'));
    expect(bindAt, isNonNegative);
    expect(calls.indexWhere(_isLink), greaterThan(bindAt));
    expect(await vault.stationLinked(), isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('手机号格式不对先拦下，不发验证码', (tester) async {
    await vault.save(_session);
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ExpressPage(runtime: buildRuntime())));
    await tester.pumpAndSettle();
    await tester.tap(find.text('绑定手机号'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('绑定其他手机号'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '手机号'), '139');
    await tester.tap(find.text('发送验证码'));
    await tester.pumpAndSettle();
    expect(find.text('请输入 11 位手机号'), findsOneWidget);
    expect(find.widgetWithText(TextField, '验证码'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('解绑在行内⋯里、要确认，确认后提示已解绑', (tester) async {
    await vault.save(_session);
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ExpressPage(runtime: buildRuntime())));
    await tester.pumpAndSettle();
    await tester.tap(find.text('绑定手机号'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('解绑'));
    await tester.pumpAndSettle();
    expect(find.textContaining('解绑'), findsWidgets);
    await tester.tap(find.widgetWithText(FilledButton, '解绑'));
    await tester.pumpAndSettle();
    expect(find.text('已解绑'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('预检查给了未绑定的已有号时出现「绑定本账号手机号」快速绑定', (tester) async {
    await vault.save(_session);
    final runtime = ToolboxRuntime.testing(
      catalog: toolboxCatalog,
      store: fixture.store,
      downloads: fixture.manager,
      services: {
        ExpressService.serviceId: ExpressService(
          vault: vault,
          clientFactory: (session) => ExpressClient(session: session, http: ExpressHttp(client: MockClient((request) async {
            final path = request.url.path;
            Map<String, Object?> body;
            if (path.endsWith('express/detail')) {
              body = {'success': true, 'error_code': '0', 'new_binding_list': const []};
            } else if (path.endsWith('pre/check')) {
              body = {'has_binding_express_mobile': false, 'mobile_id': 'mNew', 'mobile_des': '199****0000'};
            } else {
              body = {'success': true};
            }
            return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json;charset=UTF-8'});
          }))),
          antiContent: _FakeAnti(),
        ),
      },
    );
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ExpressPage(runtime: runtime)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('绑定手机号'));
    await tester.pumpAndSettle();
    expect(find.text('还没有绑定取件手机号'), findsOneWidget);
    expect(find.text('绑定本账号手机号（199****0000）'), findsOneWidget);
    await tester.tap(find.textContaining('绑定本账号手机号'));
    await tester.pumpAndSettle();
    expect(find.text('已绑定本账号手机号'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  // 身份码默认盖遮罩（人工决策见 express_identity_view.dart 的 build）。
  testWidgets('生成身份码后卡片里默认盖遮罩写「点击展开」：码与码值都不露出，勿分享提示照旧', (tester) async {
    await vault.save(_session);
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ExpressPage(runtime: buildRuntime())));
    await tester.pumpAndSettle();

    await tester.tap(find.text('身份码'));
    // 身份码视图带 1 秒周期倒计时，不能 pumpAndSettle；用定长 pump 让请求完成。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('点击展开'), findsOneWidget);
    expect(find.text('dd202610190000000000001'), findsNothing);
    expect(tester.widget<Visibility>(find.ancestor(of: find.byType(BarcodeWidget), matching: find.byType(Visibility))).visible, isFalse);
    expect(find.textContaining('有效期剩余'), findsOneWidget);
    expect(find.textContaining('请勿随意分享身份码'), findsOneWidget);
    // 销毁页面取消倒计时定时器，避免 pending timer 报错。
    await tester.pumpWidget(const SizedBox());
  });

  // 真机反馈：先查驿站（有快递时驿站卡很长）再点身份码，身份码画在驿站卡下面、落在屏幕外，要自己下滑才看到。
  testWidgets('点了按钮的结果卡滚进可视区：驿站卡已在按钮下方就不动，身份码在屏幕外时滚到整张露出；到期自动换码不滚', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 780));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await vault.save(_session);
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ExpressPage(runtime: buildRuntime(station: {
      'count': 8,
      'combine_list': [
        {
          'company_name': '合成驿站一号',
          'address': '测试路 1 号',
          'combine_track_list': [for (var index = 1; index <= 8; index++) {'pick_code': '取件码 3-2-100$index', 'shipping_name': '合成快递', 'tracking_number': 'SX000000000$index'}],
        },
      ],
    }))));
    await tester.pumpAndSettle();
    final scrollable = find.ancestor(of: find.text('合成昵称'), matching: find.byType(Scrollable)).first;
    ScrollPosition position() => tester.state<ScrollableState>(scrollable).position;

    await tester.tap(find.text('驿站快递'));
    await tester.pumpAndSettle();
    expect(find.text('取件码 3-2-1001'), findsOneWidget);
    expect(position().pixels, 0);

    await tester.tap(find.text('身份码'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    // 身份码卡第一次出现：先展开（200ms），展开完的下一帧开始滚（300ms）。
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final view = tester.getRect(scrollable);
    final card = tester.getRect(find.ancestor(of: find.byType(ExpressIdentityView), matching: find.byType(CampusSurface)));
    expect(card.top, greaterThanOrEqualTo(view.top));
    expect(card.bottom, lessThanOrEqualTo(view.bottom));
    expect(position().pixels, greaterThan(0));

    // 自己滑回顶部后，身份码到期自动换码（不是点按钮）不把页面拉走。
    position().jumpTo(0);
    await tester.pump();
    await tester.pump(const Duration(seconds: 133));
    await tester.pump(const Duration(milliseconds: 400));
    expect(position().pixels, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('点遮罩直接全屏出示：码牌从遮罩处淡入放大进整屏白底，条码转 90° 铺满长边、亮度调到最高；点一下缩回、卡片仍盖着遮罩、亮度复原', (tester) async {
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
    // 等身份码卡展开完（结果卡出现时展开淡入）。
    await tester.pump(const Duration(milliseconds: 250));

    final inline = tester.getRect(find.byType(BarcodeWidget));
    double angle() => math.atan2(tester.widget<Transform>(find.ancestor(of: find.byType(BarcodeWidget).last, matching: find.byType(Transform)).first).transform.entry(1, 0), tester.widget<Transform>(find.ancestor(of: find.byType(BarcodeWidget).last, matching: find.byType(Transform)).first).transform.entry(0, 0));
    await tester.tap(find.text('点击展开'));
    await tester.pump();
    expect(brightness, ['setApplicationScreenBrightness']);
    // 飞行途中只看得到一张：卡片里那张一直不画（上面是遮罩）、位置保留；飞的那张转到一半、已离开原位。
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
    expect(find.text('dd202610190000000000001'), findsOneWidget, reason: '码值只在全屏页里');
    expect(find.textContaining('有效期剩余'), findsNWidgets(2));
    // 全屏页有自己的透明 Material：文字取应用的默认样式，不是框架兜底的黄色双下划线样式。
    expect(DefaultTextStyle.of(tester.element(find.textContaining('有效期剩余').last)).style.debugLabel ?? '', isNot(contains('fallback')));
    expect(find.byWidgetPredicate((widget) => widget is ColoredBox && widget.color == Colors.white), findsOneWidget);

    await tester.tapAt(const Offset(30, 400));
    await tester.pump();
    expect(brightness, ['setApplicationScreenBrightness', 'resetApplicationScreenBrightness']);
    // 缩回到底的那一帧飞的那张正好落在原位、已经淡出，露出底下的遮罩；路由拿掉后卡片里仍是遮罩，码不露出。
    await tester.pump(campusExit);
    expect(tester.getRect(find.byType(BarcodeWidget).last), inline);
    expect(tester.widget<Opacity>(find.ancestor(of: find.byType(BarcodeWidget).last, matching: find.byType(Opacity)).first).opacity, 0);
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump();
    expect(find.byType(BarcodeWidget), findsOneWidget);
    expect(tester.getRect(find.byType(BarcodeWidget)), inline);
    expect(tester.widget<Visibility>(find.ancestor(of: find.byType(BarcodeWidget), matching: find.byType(Visibility))).visible, isFalse);
    expect(find.text('点击展开'), findsOneWidget);
    expect(find.text('dd202610190000000000001'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  // 「取件身份码」快捷入口（人工决策见 express_page.dart 的 _openIdentity）。
  testWidgets('快捷入口打开：先盖白底原地生成，码到了直接全屏出示（不飞入、亮度调高）、白底拿掉；关掉缩回快递首页的身份码卡', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 780));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final brightness = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('github.com/aaassseee/screen_brightness'), (call) async {
      brightness.add(call.method);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('github.com/aaassseee/screen_brightness'), null));
    await vault.save(_session);
    final gate = Completer<void>();
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ExpressPage(runtime: buildRuntime(identityGate: gate.future), openIdentity: true)));
    await tester.pump();
    await tester.pump();
    expect(find.byType(ExpressIdentityPending), findsOneWidget);
    expect(find.text('正在生成身份码'), findsOneWidget);

    gate.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump();
    await tester.pump();
    // 码到了：全屏页一出来就在终点（条码已转 90° 沿长边铺开），白底拿掉，亮度调到最高。
    expect(find.byType(ExpressIdentityPending), findsNothing);
    final zoomed = tester.getRect(find.byType(BarcodeWidget).last);
    expect(zoomed.height, greaterThan(780 * .6));
    expect(zoomed.height, greaterThan(zoomed.width * 2));
    expect(find.text('dd202610190000000000001'), findsOneWidget);
    expect(brightness, ['setApplicationScreenBrightness']);

    // 关掉全屏：缩回快递首页的身份码卡，亮度复原。
    await tester.tapAt(const Offset(30, 400));
    await tester.pump();
    await tester.pump(campusExit);
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump();
    expect(find.byType(BarcodeWidget), findsOneWidget);
    expect(find.text('点击展开'), findsOneWidget, reason: '缩回的身份码卡照样盖着遮罩');
    expect(find.text('合成昵称'), findsOneWidget);
    expect(brightness, ['setApplicationScreenBrightness', 'resetApplicationScreenBrightness']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('快捷入口打开但没登录拼多多：不盖白底，停在登录入口', (tester) async {
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ExpressPage(runtime: buildRuntime(), openIdentity: true)));
    await tester.pumpAndSettle();
    expect(find.byType(ExpressIdentityPending), findsNothing);
    expect(find.text('登录拼多多'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('快捷入口打开、码还在生成时按返回：只拿掉白底、留在快递首页，码到了不再自动全屏', (tester) async {
    await vault.save(_session);
    final gate = Completer<void>();
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ExpressPage(runtime: buildRuntime(identityGate: gate.future), openIdentity: true)));
    await tester.pump();
    await tester.pump();
    expect(find.byType(ExpressIdentityPending), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(ExpressIdentityPending), findsNothing);
    expect(find.byType(ExpressPage), findsOneWidget);
    expect(find.text('合成昵称'), findsOneWidget);

    gate.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump();
    await tester.pump();
    expect(find.text('dd202610190000000000001'), findsNothing, reason: '没有全屏，卡片里盖着遮罩');
    expect(find.text('点击展开'), findsOneWidget);
    expect(find.byType(BarcodeWidget), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('身份码卡的「添加到桌面」：注入了 pinShortcut 才有，点了按工具 id 与入口 id 请求；桌面不支持时提示条说明', (tester) async {
    await vault.save(_session);
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ExpressPage(runtime: buildRuntime())));
    await tester.pumpAndSettle();
    await tester.tap(find.text('身份码'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('添加到桌面'), findsNothing);
    await tester.pumpWidget(const SizedBox());

    final pins = <String>[];
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ExpressPage(runtime: buildRuntime(pin: (toolId, shortcutId) async {
      pins.add('$toolId.$shortcutId');
      return false;
    }))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('身份码'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.ensureVisible(find.text('添加到桌面'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('添加到桌面'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(pins, ['express.identity']);
    expect(find.text('当前桌面不支持添加快捷方式'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
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
    // 等身份码卡展开完（结果卡出现时展开淡入）。
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.text('点击展开'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('dd202610200000000000001'), findsOneWidget);
    // 两秒后到期：自动请求新码，卡片与全屏页都换成新码，倒计时从头开始。
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 50));
    expect(issued, 2);
    expect(find.text('dd202610200000000000002'), findsOneWidget);
    expect(find.text('有效期剩余 2 秒'), findsNWidgets(2));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('360dp ×1.3：卡片里遮罩的「点击展开」与全屏页的码值都保持一行，不溢出', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 780));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await vault.save(_session);
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.3)), child: child!), home: ExpressPage(runtime: buildRuntime())));
    await tester.pumpAndSettle();
    await tester.tap(find.text('身份码'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final mask = find.text('点击展开');
    expect(tester.getSize(mask).height, lessThan(16 * 1.3 * 2));
    await tester.tap(mask);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.getSize(find.text('dd202610190000000000001')).height, lessThan(20 * 1.3 * 2));
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
    // 等身份码卡展开、再滚进可视区（滚动途中不接点按）。
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('二维码'));
    await tester.pump(const Duration(milliseconds: 400));
    final inline = tester.getSize(find.byType(PrettyQrView));
    await tester.tap(find.text('点击展开'));
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
    expect(find.text('合成昵称'), findsOneWidget);
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
    await tester.tap(find.text('驿站快递'));
    await tester.pump();
    expect(find.text('正在查询'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(tester.widget<OutlinedButton>(find.ancestor(of: find.text('扫驿站码'), matching: find.byType(OutlinedButton))).onPressed, isNull);
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
    // 等身份码卡展开后滚进可视区的滚动走完（滚动途中不接点按）。
    await tester.pump(const Duration(milliseconds: 400));
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

  test('会话失效文案（非 40001）也回到登录态并清掉会话', () async {
    await vault.save(const PddSession(accessToken: 'stale'));
    final service = ExpressService(
      vault: vault,
      clientFactory: (session) => ExpressClient(
        session: session,
        http: ExpressHttp(client: MockClient((request) async => http.Response(jsonEncode({'error_code': '43001', 'error_msg': '登录状态已失效，请重新登录'}), 200, headers: {'content-type': 'application/json'}))),
      ),
    );
    final controller = ExpressController(service);
    await controller.initialize();
    expect(controller.loggedIn, isTrue);
    await expectLater(controller.reloadMobiles(), throwsA(isA<ExpressFailure>()));
    expect(controller.loggedIn, isFalse);
    expect(await vault.load(), isNull);
    controller.dispose();
  });

  testWidgets('绑定管理打开时会话已失效：弹层关闭、回到登录页写明原因', (tester) async {
    await vault.save(_session);
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ExpressPage(runtime: runtimeWith(MockClient((request) async => http.Response(jsonEncode({'error_code': 40001}), 200, headers: {'content-type': 'application/json'}))))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('绑定手机号'));
    await tester.pumpAndSettle();
    expect(find.text('取件手机号'), findsNothing);
    expect(find.text('登录拼多多'), findsOneWidget);
    expect(find.text('登录已失效，请重新登录'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
