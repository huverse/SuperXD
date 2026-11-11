import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_location.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_map_page.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_map_view.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_web_map.dart';

// 选点页经地图端口（chaoxing_map_view.dart）操作地图：这里注入假地图，记下页面交给它的标记、范围圈、平面卫星与定位请求，
// 由用例代地图回报点按、定位结果与加载状态。定位权限与系统定位开关走 permission_handler 的方法通道，打开系统定位设置走本应用的原生通道，都由用例回答。
// 网页版地图本身（内嵌网页里的高德 JS API）在测试里跑不起来，只测它的纯逻辑：网页消息的校验、导航拦截、页面填参与内置页面的安全设置。

const _permissions = MethodChannel('flutter.baseflow.com/permissions/methods');
const _locationSettings = MethodChannel('superxd/location_settings');

class _Device {
  bool serviceOn = true;
  int settingsOpened = 0;
}

class _FakeEngine implements ChaoxingMapEngine {
  _FakeEngine(this.listener, this.center, this.zoom);
  final ChaoxingMapListener listener;
  final ChaoxingMapPoint center;
  final double zoom;
  ChaoxingMapPoint? marker;
  ChaoxingMapRange? range;
  bool satellite = false;
  int rangeUpdates = 0;
  int locateCalls = 0;
  int reloads = 0;
  bool disposed = false;
  final cameraMoves = <ChaoxingMapPoint>[];
  String? approval;

  @override
  final Widget view = const SizedBox.expand(key: Key('fake-map'));

  @override
  void setMarker(ChaoxingMapPoint? point) => marker = point;

  @override
  void setRange(ChaoxingMapRange? value) {
    range = value;
    rangeUpdates++;
  }

  @override
  void setSatellite(bool value) => satellite = value;

  @override
  void locate() => locateCalls++;

  @override
  void moveCamera(ChaoxingMapPoint target, double zoom) => cameraMoves.add(target);

  @override
  String? get satelliteApproval => approval;

  @override
  void reload() {
    reloads++;
    listener.onStatus(ChaoxingMapStatus.loading);
  }

  @override
  void dispose() => disposed = true;
}

class _FakeMaps implements ChaoxingMapBackend {
  _FakeEngine? last;

  _FakeEngine get engine => last!;

  @override
  ChaoxingMapEngine open({required ChaoxingMapPoint center, required double zoom, required Color background, required ChaoxingMapListener listener}) =>
      last = _FakeEngine(listener, center, zoom);
}

const ChaoxingMapPoint _school = (latitude: 36.67, longitude: 117.35);

ChaoxingMapFix _fix(double latitude, double accuracy) => (point: (latitude: latitude, longitude: 117.35), accuracy: accuracy);

void _answerDevice(WidgetTester tester, _Device device) {
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(_permissions, (call) async => switch (call.method) {
    'requestPermissions' => {for (final permission in call.arguments as List) permission: 1},
    'checkServiceStatus' => device.serviceOn ? 1 : 0,
    _ => null,
  });
  messenger.setMockMethodCallHandler(_locationSettings, (call) async {
    device.settingsOpened++;
    return null;
  });
  addTearDown(() {
    messenger.setMockMethodCallHandler(_permissions, null);
    messenger.setMockMethodCallHandler(_locationSettings, null);
  });
}

Future<ValueNotifier<ChaoxingLocation?>> _pumpMap(WidgetTester tester, _Device device, _FakeMaps maps, {ChaoxingLocation? selected, double textScale = 1}) async {
  _answerDevice(tester, device);
  final value = ValueNotifier<ChaoxingLocation?>(selected);
  await tester.pumpWidget(
    MaterialApp(
      theme: campusTheme(),
      builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)), child: child!),
      home: Scaffold(
        body: ValueListenableBuilder(
          valueListenable: value,
          builder: (context, location, _) => ChaoxingInlineMap(selected: location, onPicked: (picked) => value.value = picked, onExpand: null, backend: maps),
        ),
      ),
    ),
  );
  await tester.pump();
  return value;
}

Future<void> _locate(WidgetTester tester, _FakeMaps maps, ChaoxingMapFix fix) async {
  maps.engine.listener.onFix(fix);
  await tester.pump();
}

const _remembered = ChaoxingLocation(latitude: 36.68, longitude: 117.36, address: '知敬楼', system: ChaoxingCoordinateSystem.gcj02);

void main() {
  testWidgets('系统定位关着：地图左上角写明没开并给「去打开」，打开回来第一次定位结果照样选中', (tester) async {
    final device = _Device()..serviceOn = false;
    final maps = _FakeMaps();
    final selected = await _pumpMap(tester, device, maps);
    expect(find.text('手机定位没开'), findsOneWidget);
    expect(find.text('正在定位…'), findsNothing);
    expect(maps.engine.locateCalls, 1, reason: '定位没开也照常开始定位，打开回来就能接着取到');

    await tester.tap(find.byTooltip('定位到我'));
    await tester.pump();
    expect(find.byTooltip('正在定位'), findsNothing, reason: '定位没开时按钮不转圈');
    await tester.tap(find.text('去打开'));
    await tester.pump();
    expect(device.settingsOpened, 1);

    device.serviceOn = true;
    await _locate(tester, maps, _fix(36.67, 550));
    expect(selected.value?.latitude, 36.67);
    expect(selected.value?.system, ChaoxingCoordinateSystem.gcj02);
    expect(find.text('手机定位没开'), findsNothing);
  });

  testWidgets('系统定位关着而已有选中的位置：平时不提示，点了定位到我才写明没开', (tester) async {
    final device = _Device()..serviceOn = false;
    // 弹层里地图约 300 宽，大字号下提示与「去打开」也排得下（溢出会让用例报错）。
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await _pumpMap(tester, device, _FakeMaps(), selected: _remembered, textScale: 1.6);
    expect(find.text('手机定位没开'), findsNothing);
    await tester.tap(find.byTooltip('定位到我'));
    await tester.pump();
    expect(find.text('手机定位没开'), findsOneWidget);
    expect(find.text('去打开'), findsOneWidget);
  });

  testWidgets('定位来的默认选点跟着更准的结果走，点过地图就不再动；标记跟着选中的位置', (tester) async {
    final maps = _FakeMaps();
    final selected = await _pumpMap(tester, _Device(), maps);
    expect(maps.engine.locateCalls, 1, reason: '进位置签到就开始定位');
    expect(maps.engine.marker, isNull);
    expect(find.text('正在定位…'), findsOneWidget);

    await _locate(tester, maps, _fix(36.671, 550));
    expect(selected.value?.latitude, 36.671, reason: '第一次定位结果就是默认选中');
    expect(maps.engine.cameraMoves.last.latitude, 36.671, reason: '镜头跟到定位结果');
    expect(maps.engine.marker?.latitude, 36.671);
    await _locate(tester, maps, _fix(36.672, 30));
    expect(selected.value?.latitude, 36.672, reason: '更准的结果来了就换过去');
    await _locate(tester, maps, _fix(36.673, 40));
    expect(selected.value?.latitude, 36.672, reason: '没更准的不换');

    final moves = maps.engine.cameraMoves.length;
    maps.engine.listener.onTap(_school);
    await tester.pump();
    expect(selected.value?.latitude, _school.latitude);
    expect(maps.engine.cameraMoves, hasLength(moves), reason: '自己点的点不挪镜头，免得点哪儿跳哪儿');
    await _locate(tester, maps, _fix(36.674, 5));
    expect(selected.value?.latitude, _school.latitude, reason: '自己点过地图就以点的为准');
  });

  testWidgets('全屏选点带着签到页已选的位置进来：标记画上、可以直接用；点地图时范围圈不重画；添加收藏不预选', (tester) async {
    _answerDevice(tester, _Device());
    final maps = _FakeMaps();
    await tester.pumpWidget(
      MaterialApp(theme: campusTheme(), home: ChaoxingMapPage(initial: _remembered, rangeCenter: _remembered, rangeMeters: 100, backend: maps)),
    );
    await tester.pump();
    // 以前进来是空的，标记不画、「用这个位置」灰着，要再点一次。
    expect(find.text('已选 36.680000, 117.360000'), findsOneWidget);
    final use = find.ancestor(of: find.text('用这个位置'), matching: find.byWidgetPredicate((widget) => widget is FilledButton));
    expect(tester.widget<FilledButton>(use).enabled, isTrue);
    expect(maps.engine.marker, (latitude: 36.68, longitude: 117.36));
    expect(maps.engine.range?.meters, 100);
    expect(maps.engine.range?.center, (latitude: 36.68, longitude: 117.36));
    expect(maps.engine.rangeUpdates, 1);
    expect(maps.engine.locateCalls, 0, reason: '全屏页不自动定位');
    maps.engine.listener.onTap(_school);
    await tester.pump();
    expect(find.text('已选 36.670000, 117.350000'), findsOneWidget);
    expect(maps.engine.marker, _school);
    expect(maps.engine.rangeUpdates, 1, reason: '范围圈按内容比较，点地图不重画（重画会闪）');

    await tester.pumpWidget(const SizedBox());
    expect(maps.engine.disposed, isTrue, reason: '离开页面时关掉地图');

    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ChaoxingMapPage(initial: _remembered, favorite: true, backend: maps)));
    await tester.pump();
    expect(find.text('在教室的位置点一下地图'), findsOneWidget);
    expect(maps.engine.marker, isNull);
    expect(maps.engine.center, (latitude: 36.68, longitude: 117.36), reason: '最近的收藏只当镜头起点');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('跟随最多 30 秒；外面换了位置（选收藏）也不再跟', (tester) async {
    final maps = _FakeMaps();
    final selected = await _pumpMap(tester, _Device(), maps);
    await _locate(tester, maps, _fix(36.671, 550));
    await tester.pump(const Duration(seconds: 31));
    await _locate(tester, maps, _fix(36.672, 10));
    expect(selected.value?.latitude, 36.671, reason: '过了跟随窗口不再换');

    // 点「定位到我」重新开始跟随：先用手上的结果选中，再来更准的接着换。
    await tester.tap(find.byTooltip('定位到我'));
    await tester.pump();
    expect(selected.value?.latitude, 36.672);
    await _locate(tester, maps, _fix(36.673, 8));
    expect(selected.value?.latitude, 36.673);
    const favorite = ChaoxingLocation(latitude: 36.68, longitude: 117.36, address: '知敬楼', system: ChaoxingCoordinateSystem.gcj02);
    selected.value = favorite;
    await tester.pump();
    expect(maps.engine.cameraMoves.last, (latitude: 36.68, longitude: 117.36), reason: '选了收藏镜头跟过去');
    await _locate(tester, maps, _fix(36.675, 5));
    expect(selected.value, favorite, reason: '选了收藏就以收藏为准');
  });

  testWidgets('已经有选中的位置（这门课上次用的）时不拿定位结果覆盖', (tester) async {
    final maps = _FakeMaps();
    final selected = await _pumpMap(tester, _Device(), maps, selected: _remembered);
    expect(maps.engine.center, (latitude: 36.68, longitude: 117.36), reason: '镜头从选中的位置开始');
    await _locate(tester, maps, _fix(36.671, 550));
    await _locate(tester, maps, _fix(36.672, 10));
    expect(selected.value, _remembered);
  });

  testWidgets('地图没加载出来：正中写明并给「重试」，重试时提示收起', (tester) async {
    final maps = _FakeMaps();
    await _pumpMap(tester, _Device(), maps);
    expect(find.text('正在定位…'), findsOneWidget);
    maps.engine.listener.onStatus(ChaoxingMapStatus.failed);
    await tester.pump();
    expect(find.text('地图没加载出来'), findsOneWidget);
    expect(find.text('正在定位…'), findsNothing, reason: '地图都没出来，不写「正在定位」「点一下地图」');
    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(maps.engine.reloads, 1);
    expect(find.text('地图没加载出来'), findsNothing);
    expect(find.text('正在定位…'), findsOneWidget);
  });

  testWidgets('平面卫星切换交给地图，卫星图画好后标出审图号', (tester) async {
    final maps = _FakeMaps();
    await _pumpMap(tester, _Device(), maps);
    maps.engine.approval = 'GS(2025)1807';
    maps.engine.listener.onStatus(ChaoxingMapStatus.ready);
    await tester.pump();
    expect(find.text('GS(2025)1807'), findsNothing, reason: '平面图不标');
    await tester.tap(find.byTooltip('卫星地图'));
    await tester.pump();
    expect(maps.engine.satellite, isTrue);
    expect(find.text('GS(2025)1807'), findsOneWidget);
    await tester.tap(find.byTooltip('平面地图'));
    await tester.pump();
    expect(maps.engine.satellite, isFalse);
    expect(find.text('GS(2025)1807'), findsNothing);
  });

  group('网页版地图', () {
    test('网页消息按外部输入逐项校验，对不上的整条丢掉', () {
      expect(chaoxingMapMessage('{"type":"tap","latitude":36.67,"longitude":117.35}'), isA<ChaoxingMapTapped>().having((message) => message.point, 'point', (latitude: 36.67, longitude: 117.35)));
      expect(chaoxingMapMessage('{"type":"tap","latitude":91,"longitude":117.35}'), isNull);
      expect(chaoxingMapMessage('{"type":"tap","latitude":36.67,"longitude":-181}'), isNull);
      expect(chaoxingMapMessage('{"type":"tap","latitude":"36.67","longitude":117.35}'), isNull);
      expect(chaoxingMapMessage('{"type":"tap","latitude":36.67}'), isNull);
      expect(
        chaoxingMapMessage('{"type":"located","latitude":36.67,"longitude":117.35,"accuracy":550}'),
        isA<ChaoxingMapLocated>().having((message) => message.accuracy, 'accuracy', 550),
      );
      expect(chaoxingMapMessage('{"type":"located","latitude":36.67,"longitude":117.35,"accuracy":-1}'), isNull);
      expect(chaoxingMapMessage('{"type":"located","latitude":36.67,"longitude":117.35,"accuracy":1e9}'), isNull);
      expect(chaoxingMapMessage('{"type":"located","latitude":36.67,"longitude":117.35}'), isNull);
      expect(chaoxingMapMessage('{"type":"ready","approval":"GS(2025)1807"}'), isA<ChaoxingMapReady>().having((message) => message.approval, 'approval', 'GS(2025)1807'));
      expect(chaoxingMapMessage('{"type":"ready","approval":null}'), isA<ChaoxingMapReady>().having((message) => message.approval, 'approval', isNull));
      expect(chaoxingMapMessage('{"type":"ready","approval":"<b>GS</b>"}'), isNull);
      expect(chaoxingMapMessage('{"type":"ready","approval":"${'号' * 41}"}'), isNull);
      for (final reason in ['script', 'key', 'init']) {
        expect(chaoxingMapMessage('{"type":"failed","reason":"$reason"}'), isA<ChaoxingMapFailed>().having((message) => message.reason, 'reason', reason));
      }
      expect(chaoxingMapMessage('{"type":"failed","reason":"other"}'), isNull);
      expect(chaoxingMapMessage('{"type":"locateFailed","code":1}'), isA<ChaoxingMapLocateFailed>());
      expect(chaoxingMapMessage('{"type":"locateFailed","code":4}'), isNull);
      expect(chaoxingMapMessage('{"type":"locateFailed","code":1.5}'), isNull);
      expect(chaoxingMapMessage('{"type":"blocked","host":"g.alicdn.com"}'), isA<ChaoxingMapBlocked>().having((message) => message.host, 'host', 'g.alicdn.com'));
      expect(chaoxingMapMessage('{"type":"blocked","host":"a.com/?key=1"}'), isNull);
      expect(chaoxingMapMessage('{"type":"navigate","url":"https://example.com"}'), isNull);
      expect(chaoxingMapMessage('[1,2]'), isNull);
      expect(chaoxingMapMessage('not json'), isNull);
      expect(chaoxingMapMessage('{"type":"tap","latitude":36.67,"longitude":117.35,"pad":"${'x' * 600}"}'), isNull, reason: '超长的整条丢掉');
    });

    test('主框架只许停在内置页', () {
      expect(chaoxingMapNavigation(chaoxingMapPageUrl), NavigationDecision.navigate);
      expect(chaoxingMapNavigation('$chaoxingMapPageUrl#top'), NavigationDecision.navigate);
      for (final url in [
        'http://localhost/superxd/chaoxing_map.html',
        'https://localhost/superxd/other.html',
        'https://localhost.evil.com/superxd/chaoxing_map.html',
        'https://webapi.amap.com/maps?v=2.0',
        'https://www.amap.com/',
        'amapuri://route/plan',
        'intent://open#Intent;end',
        'about:blank',
        'javascript:alert(1)',
      ]) {
        expect(chaoxingMapNavigation(url), NavigationDecision.prevent, reason: url);
      }
    });

    test('页面填参：key、密钥、镜头与底色进 JSON，< 转义，占位不唯一就报错', () {
      const template = '<script>var config = /*CONFIG*/null;</script>';
      final html = chaoxingMapHtml(
        template,
        key: 'k</script><script>alert(1)',
        secret: 'secret',
        center: (latitude: 36.67, longitude: 117.35),
        zoom: 17,
        background: const Color(0xFF102030),
      );
      expect('</script>'.allMatches(html), hasLength(1), reason: 'key 里的 </script> 不能提前结束脚本');
      final json = html.substring('<script>var config = '.length, html.length - ';</script>'.length);
      expect(jsonDecode(json), {'key': 'k</script><script>alert(1)', 'secret': 'secret', 'center': [36.67, 117.35], 'zoom': 17, 'background': '#102030'});
      expect(() => chaoxingMapHtml('<script></script>', key: 'k', secret: 's', center: (latitude: 0, longitude: 0), zoom: 4, background: const Color(0xFFFFFFFF)), throwsStateError);
      expect(
        () => chaoxingMapHtml('/*CONFIG*/null /*CONFIG*/null', key: 'k', secret: 's', center: (latitude: 0, longitude: 0), zoom: 4, background: const Color(0xFFFFFFFF)),
        throwsStateError,
      );
    });

    test('内置页面：只许高德的域名，安全密钥在加载脚本之前设置，不画精度圈', () {
      final html = File('assets/chaoxing_map/map.html').readAsStringSync();
      expect(File('pubspec.yaml').readAsStringSync(), contains('    - assets/chaoxing_map/\n'));
      expect('/*CONFIG*/null'.allMatches(html), hasLength(1));
      final policy = RegExp(r'http-equiv="Content-Security-Policy" content="([^"]+)"').firstMatch(html)!.group(1)!;
      final directives = {for (final part in policy.split(';').map((part) => part.trim().split(' '))) part.first: part.skip(1).toSet()};
      expect(directives['default-src'], {"'none'"});
      const allowed = {"'unsafe-inline'", "'unsafe-eval'", 'data:', 'blob:', 'https://*.amap.com', 'https://*.is.autonavi.com'};
      for (final MapEntry(:key, :value) in directives.entries) {
        expect(allowed.containsAll(value) || value.contains("'none'"), isTrue, reason: '$key 放行了 ${value.difference(allowed)}');
      }
      expect(directives.keys, isNot(contains('frame-src')));
      final secret = html.indexOf('window._AMapSecurityConfig = { securityJsCode: config.secret }');
      final loader = html.indexOf("'https://webapi.amap.com/maps?v=2.0&key='");
      final append = html.indexOf('document.head.appendChild(script)');
      expect(secret, greaterThan(0));
      expect(loader, greaterThan(secret));
      expect(append, greaterThan(loader));
      expect('new AMap.Circle('.allMatches(html), hasLength(1), reason: '只有签到范围圈，定位不画精度圈');
      expect('watchPosition('.allMatches(html), hasLength(1), reason: '只在应用要定位时才取位置');
      expect(html, isNot(contains('AMap.Geolocation')), reason: '定位不经高德，位置不发给高德');
    });
  });
}
