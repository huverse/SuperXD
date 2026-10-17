import 'package:amap_map/amap_map.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:x_amap_base/x_amap_base.dart';

import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_location.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_map_page.dart';

// 签到弹层里嵌的地图：测试平台设成 linux，高德插件只画一行占位文字，定位结果与点按由用例直接调 AMapWidget 的回调；
// 定位权限与系统定位开关走 permission_handler 的方法通道，打开系统定位设置走本应用的原生通道，都由用例回答。

const _permissions = MethodChannel('flutter.baseflow.com/permissions/methods');
const _locationSettings = MethodChannel('superxd/location_settings');

class _Device {
  bool serviceOn = true;
  int settingsOpened = 0;
}

const _school = LatLng(36.67, 117.35);

AMapLocation _fix(double latitude, double accuracy) =>
    AMapLocation(latLng: LatLng(latitude, 117.35), accuracy: accuracy, provider: accuracy > 100 ? 'lbs' : 'gps');

// 平台覆盖要在用例体结束前复位（框架在 tearDown 之前就检查调试变量）。
void _mapTest(String description, Future<void> Function(WidgetTester tester) body) => testWidgets(description, (tester) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  try {
    await body(tester);
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
});

Future<ValueNotifier<ChaoxingLocation?>> _pumpMap(WidgetTester tester, _Device device, {ChaoxingLocation? selected, double textScale = 1}) async {
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
  final value = ValueNotifier<ChaoxingLocation?>(selected);
  await tester.pumpWidget(
    MaterialApp(
      theme: campusTheme(),
      builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)), child: child!),
      home: Scaffold(
        body: ValueListenableBuilder(
          valueListenable: value,
          builder: (context, location, _) => ChaoxingInlineMap(selected: location, onPicked: (picked) => value.value = picked, onExpand: null),
        ),
      ),
    ),
  );
  await tester.pump();
  return value;
}

AMapWidget _map(WidgetTester tester) => tester.widget<AMapWidget>(find.byType(AMapWidget));

Future<void> _locate(WidgetTester tester, AMapLocation location) async {
  _map(tester).onLocationChanged!(location);
  await tester.pump();
}

void main() {
  _mapTest('系统定位关着：地图左上角写明没开并给「去打开」，打开回来第一次定位结果照样选中', (tester) async {
    final device = _Device()..serviceOn = false;
    final selected = await _pumpMap(tester, device);
    expect(find.text('手机定位没开'), findsOneWidget);
    expect(find.text('正在定位…'), findsNothing);

    await tester.tap(find.byTooltip('定位到我'));
    await tester.pump();
    expect(find.byTooltip('正在定位'), findsNothing, reason: '定位没开时按钮不转圈');
    await tester.tap(find.text('去打开'));
    await tester.pump();
    expect(device.settingsOpened, 1);

    // 定位关着时图层回报的是 0,0，不当结果；打开回来后第一次真实结果就是默认选中。
    await _locate(tester, const AMapLocation(latLng: LatLng(0, 0)));
    expect(selected.value, isNull);
    device.serviceOn = true;
    await _locate(tester, _fix(36.67, 550));
    expect(selected.value?.latitude, 36.67);
    expect(find.text('手机定位没开'), findsNothing);
  });

  _mapTest('系统定位关着而已有选中的位置：平时不提示，点了定位到我才写明没开', (tester) async {
    const remembered = ChaoxingLocation(latitude: 36.68, longitude: 117.36, address: '知敬楼', system: ChaoxingCoordinateSystem.gcj02);
    final device = _Device()..serviceOn = false;
    // 弹层里地图约 300 宽，大字号下提示与「去打开」也排得下（溢出会让用例报错）。
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await _pumpMap(tester, device, selected: remembered, textScale: 1.6);
    expect(find.text('手机定位没开'), findsNothing);
    await tester.tap(find.byTooltip('定位到我'));
    await tester.pump();
    expect(find.text('手机定位没开'), findsOneWidget);
    expect(find.text('去打开'), findsOneWidget);
  });

  _mapTest('定位来的默认选点跟着更准的结果走，点过地图就不再动；精度圈不画', (tester) async {
    final selected = await _pumpMap(tester, _Device());
    final style = _map(tester).myLocationStyleOptions!;
    expect(style.enabled, isTrue);
    expect(style.circleFillColor, Colors.transparent);
    expect(style.circleStrokeColor, Colors.transparent);
    expect(find.text('正在定位…'), findsOneWidget);

    await _locate(tester, _fix(36.671, 550));
    expect(selected.value?.latitude, 36.671, reason: '第一次定位结果就是默认选中');
    await _locate(tester, _fix(36.672, 30));
    expect(selected.value?.latitude, 36.672, reason: '更准的结果来了就换过去');
    await _locate(tester, _fix(36.673, 40));
    expect(selected.value?.latitude, 36.672, reason: '没更准的不换');

    _map(tester).onTap!(_school);
    await tester.pump();
    expect(selected.value?.latitude, _school.latitude);
    await _locate(tester, _fix(36.674, 5));
    expect(selected.value?.latitude, _school.latitude, reason: '自己点过地图就以点的为准');
  });

  _mapTest('全屏选点带着签到页已选的位置进来：标记画上、可以直接用；点地图时范围圈不重建；添加收藏不预选', (tester) async {
    const chosen = ChaoxingLocation(latitude: 36.68, longitude: 117.36, address: '知敬楼', system: ChaoxingCoordinateSystem.gcj02);
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: const ChaoxingMapPage(initial: chosen, rangeCenter: chosen, rangeMeters: 100)));
    await tester.pump();
    // 以前进来是空的，标记不画、「用这个位置」灰着，要再点一次。
    expect(find.text('已选 36.680000, 117.360000'), findsOneWidget);
    final use = find.ancestor(of: find.text('用这个位置'), matching: find.byWidgetPredicate((widget) => widget is FilledButton));
    expect(tester.widget<FilledButton>(use).enabled, isTrue);
    expect(_map(tester).markers, hasLength(1));
    final polygons = _map(tester).polygons;
    expect(polygons, hasLength(1));
    _map(tester).onTap!(_school);
    await tester.pump();
    expect(identical(_map(tester).polygons, polygons), isTrue, reason: '范围圈按内容缓存，点地图不重建（重建就是新 id，高德删了重画会闪）');

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: const ChaoxingMapPage(initial: chosen, favorite: true)));
    await tester.pump();
    expect(find.text('在教室的位置点一下地图'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  _mapTest('跟随最多 30 秒；外面换了位置（选收藏）也不再跟', (tester) async {
    final selected = await _pumpMap(tester, _Device());
    await _locate(tester, _fix(36.671, 550));
    await tester.pump(const Duration(seconds: 31));
    await _locate(tester, _fix(36.672, 10));
    expect(selected.value?.latitude, 36.671, reason: '过了跟随窗口不再换');

    // 点「定位到我」重新开始跟随：先用手上的结果选中，再来更准的接着换。
    await tester.tap(find.byTooltip('定位到我'));
    await tester.pump();
    expect(selected.value?.latitude, 36.672);
    await _locate(tester, _fix(36.673, 8));
    expect(selected.value?.latitude, 36.673);
    const favorite = ChaoxingLocation(latitude: 36.68, longitude: 117.36, address: '知敬楼', system: ChaoxingCoordinateSystem.gcj02);
    selected.value = favorite;
    await tester.pump();
    await _locate(tester, _fix(36.675, 5));
    expect(selected.value, favorite, reason: '选了收藏就以收藏为准');
  });

  _mapTest('已经有选中的位置（这门课上次用的）时不拿定位结果覆盖', (tester) async {
    const remembered = ChaoxingLocation(latitude: 36.68, longitude: 117.36, address: '知敬楼', system: ChaoxingCoordinateSystem.gcj02);
    final selected = await _pumpMap(tester, _Device(), selected: remembered);
    await _locate(tester, _fix(36.671, 550));
    await _locate(tester, _fix(36.672, 10));
    expect(selected.value, remembered);
  });
}
